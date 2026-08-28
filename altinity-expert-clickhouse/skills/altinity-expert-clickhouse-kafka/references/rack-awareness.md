# Kafka Rack Awareness and Cross-AZ Traffic

Use this reference for ClickHouse Kafka-engine tables that consume from AWS MSK
or another rack-aware Kafka cluster. Start here when `client.rack`,
`KAFKA_CLIENT_RACK`, cross-AZ cost, VPC endpoint routing, or an MSK cutover is
part of the incident.

## What `client.rack` changes

`client.rack` lets a Kafka consumer prefer a follower in the same rack. It
affects consumer fetch routing only. It does not make producer traffic,
metadata requests, leader traffic, or every control-plane request local.

Kafka matches the consumer rack and broker rack as exact strings. Match the
broker's reported rack value, not its broker ID. A consumer in `euc1-az2` must
use `euc1-az2`; `eu-central-1b` is a different string.

On AWS, use an Availability Zone ID such as `euc1-az2` when the broker rack
configuration uses Zone IDs. Do not derive a rack from an AZ letter suffix
such as `eu-central-1b`: AWS can map those names to different physical zones
in different accounts.

## Check the broker side first

`client.rack` does nothing on its own. The brokers must select replicas by
rack, and by default they do not: `replica.selector.class` defaults to
`LeaderSelector`, which always returns the partition leader no matter what
rack the consumer advertises. Follower fetching also needs Kafka 2.4 or later
on both sides (KIP-392).

Confirm the broker setting before changing anything in ClickHouse:

```bash
kafka-configs.sh --broker <id> --all --describe \
  --bootstrap-server <broker>:<port> \
  --command-config /opt/kafka/config/client.properties \
  | grep replica.selector.class
```

The value must be `org.apache.kafka.common.replica.RackAwareReplicaSelector`.
On MSK it is set through a cluster configuration, not per broker, so a change
requires applying a new MSK configuration revision. If the selector is absent
or set to the default, stop here: a correct `KAFKA_CLIENT_RACK` cannot reduce
cross-AZ traffic until the brokers select by rack.

## Configure ClickHouse once per pod

Set the client rack globally in a file such as
`config.d/kafka_rack.xml`. Inject the actual value through each ClickHouse
pod's environment. Do not hardcode it in individual Kafka tables.

```xml
<clickhouse>
    <kafka>
        <client_rack from_env="KAFKA_CLIENT_RACK"/>
    </kafka>
</clickhouse>
```

For example, a ClickHouse pod template can set the value for a pod in
`euc1-az2`:

```yaml
spec:
  containers:
    - name: clickhouse-pod
      env:
        - name: KAFKA_CLIENT_RACK
          value: euc1-az2
```

Check the expanded configuration rather than trusting the source manifest:

```bash
kubectl exec <pod> -- \
  grep -A2 client_rack /var/lib/clickhouse/preprocessed_configs/config.xml
```

The setting must appear under `<kafka>`, and it must have a non-empty expanded
value. A missing or empty setting means the environment variable did not reach
the ClickHouse container.

## Verify rack IDs and pod location

Follow this order. Do not infer the broker rack from its hostname or ID.

1. Read the rack string from each broker's own configuration. Repeat per
   broker ID; `broker.rack` is a per-broker value.

   ```bash
   kafka-configs.sh --broker <id> --all --describe \
     --bootstrap-server <broker>:<port> \
     --command-config /opt/kafka/config/client.properties \
     | grep broker.rack
   ```

   Supply the required TLS or SASL options for the target cluster in the
   command-config file. Java tools may use a JAAS file. ClickHouse
   Kafka-engine tables use their own table settings, not that JAAS file.

   On MSK, `aws kafka list-nodes --cluster-arn <arn>` gives the same picture
   from the AWS API when Kafka tooling is not reachable. MSK sets
   `broker.rack` to the Availability Zone ID, such as `use1-az4`.

   Do not read racks from `kafka-broker-api-versions.sh` or `kcat -L`. Neither
   reports `broker.rack`; both list broker IDs and endpoints only.

2. Confirm that every `KAFKA_CLIENT_RACK` string matches a broker rack string.
   A mismatch fails silently and disables rack-aware fetching.

3. Confirm that each pod reports its real physical location. On EKS, inspect
   the node hosting the pod and compare its AWS Zone ID label with the
   environment value.

   ```bash
   kubectl get pod <pod> -n <namespace> \
     -o jsonpath='{.spec.nodeName}{"\n"}'
   kubectl get node <node> \
     -o jsonpath='{.metadata.labels.topology\.k8s\.aws/zone-id}{"\n"}'
   ```

   If the AWS-specific label is absent, list the node's zone-related labels
   and establish the cluster's authoritative Zone ID source. The standard
   Kubernetes zone labels normally carry AZ letter names, so do not compare
   them directly to Zone IDs.

4. List every ClickHouse pod before checking a selected pod template. A
   namespace can include pods from more than one ClickHouse installation.

   ```bash
   kubectl get pods -n <namespace> -o wide
   ```

If a pod's physical Zone ID differs from `KAFKA_CLIENT_RACK`, the consumer is
advertising the wrong location. Correct the pod configuration and roll it out
before assessing traffic distribution.

## Recognize an intentional AZ gap

Compare distinct broker racks with the `KAFKA_CLIENT_RACK` values in use. A
broker rack with no matching ClickHouse replica means traffic for that rack is
unavoidably cross-AZ. This is not automatically a misconfiguration.

Confirm whether ClickHouse capacity exists in the missing zone. For Altinity
Cloud node pools, for example:

```bash
kubectl get nodes -l node.altinity.cloud/role.clickhouse=true \
  -o custom-columns=NAME:.metadata.name,ZONE-ID:'.metadata.labels.topology\.k8s\.aws/zone-id'
```

If that zone has no ClickHouse nodes, adding or placing a replica there is the
only client-side topology change that can remove the gap. Treat the cost as an
accepted topology tradeoff unless the deployment requirements say otherwise.

## Confirm Kafka traffic and separate other costs

First, confirm that the ClickHouse table is connected to the intended brokers:

```sql
SELECT
    hostName() AS host,
    database,
    name,
    engine_full
FROM clusterAllReplicas('{cluster}', system.tables)
WHERE engine LIKE '%Kafka%'
ORDER BY database ASC, name ASC, host ASC
LIMIT 100
;
```

Then inspect consumers on every replica. Advancing offsets with no current
exceptions are strong evidence that the configured endpoint is reachable, and
per-host output is what shows a single replica behaving differently from the
rest.

```sql
SELECT
    hostName() AS host,
    database,
    `table`,
    num_messages_read,
    last_poll_time,
    last_commit_time,
    is_currently_used,
    exceptions.time[-1] AS last_exception_time,
    left(exceptions.text[-1], 200) AS last_exception_text
FROM clusterAllReplicas('{cluster}', system.kafka_consumers)
WHERE database = '<db>'
  AND `table` = '<kafka_table>'
ORDER BY host ASC
;
```

Never `SELECT *` from `system.kafka_consumers`: the `rdkafka_stat` column is a
large JSON document per consumer.

Enable and inspect `rdkafka_stat` only when a detailed broker-traffic view is
needed. Its broker statistics expose per-broker byte counters (`rxbytes` and
`txbytes`) for each ClickHouse host. Do not use `rx` and `tx` for this: those
are request and response counts, not bytes. Capture two snapshots after
rollout and compare the deltas. Correlate broker addresses with their verified
rack IDs; do not label traffic as local from the broker ID alone.

Use VPC Flow Logs or AWS Cost and Usage Report data to attribute dollars. A
VPC endpoint ENI (`vpce-*`) points to endpoint-related Kafka traffic. Pod or
node ENIs normally identify ClickHouse-to-ClickHouse traffic.

Do not assume every cross-AZ charge is Kafka traffic. Kafka uses the broker
listener ports configured for the cluster. ClickHouse interserver traffic uses
the deployment's interserver port, often `9009`. Investigate replication when
traffic occurs on ClickHouse ports or when it persists independently of Kafka
consumer activity.

Load `altinity-expert-clickhouse-replication` for that investigation rather
than running replication queries from here. Rack-aware Kafka fetching cannot
reduce replica-to-replica transfer.

## Check VPC endpoint routing

For cross-account MSK reached through a VPC endpoint, a correct `client.rack`
does not ensure same-AZ network routing. The endpoint must expose an ENI in
each AZ used by ClickHouse, and the subnet-to-AZ mapping must be correct.

Check the endpoint and its network interfaces with your cloud operator or the
AWS CLI. From each ClickHouse pod, resolve broker hostnames and confirm that
they resolve to an endpoint ENI in the pod's Zone ID. Correct endpoint subnet
placement before treating `client.rack` as ineffective.

## Handle a new MSK cluster

When replacing an MSK cluster, re-read the broker rack strings after cutover.
ClickHouse needs no change if the new cluster reports the same rack strings,
even if broker IDs changed. Update `KAFKA_CLIENT_RACK` only when the broker
rack naming scheme changed or rack awareness is no longer available.

After cutover, verify consumer progress, inspect exceptions and DNS errors,
and repeat the broker-traffic comparison. Check the configured broker
endpoints against the cluster's current bootstrap-broker list. A hostname or
port you do not recognize is not automatically wrong, but it is worth
confirming before you attribute traffic to it.

## Practical failure modes

- The brokers still use the default `LeaderSelector`. Every consumer fetch
  goes to the leader and `client.rack` is ignored. This is the most common
  reason a correct client rack changes nothing.
- An exact-string mismatch fails silently; Kafka does not warn that rack-aware
  fetching was skipped.
- A correct rack value cannot compensate for a VPC endpoint that routes through
  another AZ.
- A gap between broker racks and ClickHouse racks may be intentional. Confirm
  compute placement before calling it a configuration defect.
- Check all ClickHouse pods in the namespace. An older or separate installation
  can make the traffic picture look inconsistent.
