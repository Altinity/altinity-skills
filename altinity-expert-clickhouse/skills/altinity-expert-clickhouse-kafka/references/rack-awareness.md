# Kafka Rack Awareness and Cross-AZ Traffic

Use this reference for ClickHouse Kafka-engine tables that consume from AWS MSK
or another rack-aware Kafka cluster. Start here when `client.rack`,
`KAFKA_CLIENT_RACK`, cross-AZ cost, VPC endpoint routing, or an MSK cutover is
part of the incident.

## What `client.rack` changes

`client.rack` lets a Kafka consumer prefer a follower in the same rack when
the broker cluster supports follower fetching. It affects consumer fetch
routing only. It does not make producer traffic, metadata requests, leader
traffic, or every control-plane request local.

Kafka matches the consumer rack and broker rack as exact strings. Match the
broker's reported rack value, not its broker ID. A consumer in `euc1-az2` must
use `euc1-az2`; `eu-central-1b` is a different string.

On AWS, use an Availability Zone ID such as `euc1-az2` when the broker rack
configuration uses Zone IDs. Do not derive a rack from an AZ letter suffix
such as `eu-central-1b`: AWS can map those names to different physical zones
in different accounts.

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

1. List broker rack strings with a Kafka client that can reach the cluster.
   The exact command depends on authentication, but either Java Kafka tooling
   or `kcat` can expose broker metadata.

   ```bash
   kafka-broker-api-versions.sh \
     --bootstrap-server <broker>:<port> \
     --command-config /opt/kafka/config/client-sasl.properties \
     --list-brokers | grep rack
   ```

   ```bash
   kcat -L -b <broker>:<port> \
     -X security.protocol=SASL_SSL \
     -X sasl.mechanism=SCRAM-SHA-512
   ```

   Supply the required TLS or SASL options for the target cluster. Java tools
   may use a JAAS file. ClickHouse Kafka-engine tables use their own table
   settings, not that JAAS file.

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
  -o custom-columns=NAME:.metadata.name,ZONE-ID:'{.metadata.labels.topology.k8s.aws/zone-id}'
```

If that zone has no ClickHouse nodes, adding or placing a replica there is the
only client-side topology change that can remove the gap. Treat the cost as an
accepted topology tradeoff unless the deployment requirements say otherwise.

## Confirm Kafka traffic and separate other costs

First, confirm that the ClickHouse table is connected to the intended brokers:

```sql
SELECT database, name, create_table_query
FROM system.tables
WHERE engine LIKE '%Kafka%';
```

Then inspect consumers. Advancing offsets with no current exceptions are
strong evidence that the configured endpoint is reachable.

```sql
SELECT *
FROM system.kafka_consumers
WHERE database = '<db>'
  AND table = '<kafka_table>';
```

Enable and inspect `rdkafka_stat` only when a detailed broker-traffic view is
needed. Its broker statistics can show received and transmitted byte counters
per ClickHouse host and Kafka broker. Capture two snapshots after rollout and
compare the deltas. Correlate broker addresses with their verified rack IDs;
do not label traffic as local from the broker ID alone.

Use VPC Flow Logs or AWS Cost and Usage Report data to attribute dollars. A
VPC endpoint ENI (`vpce-*`) points to endpoint-related Kafka traffic. Pod or
node ENIs normally identify ClickHouse-to-ClickHouse traffic.

Do not assume every cross-AZ charge is Kafka traffic. Kafka uses the broker
listener ports configured for the cluster. ClickHouse interserver traffic uses
the deployment's interserver port, often `9009`. Investigate replication when
traffic occurs on ClickHouse ports or when it persists independently of Kafka
consumer activity:

```sql
SELECT * FROM system.replicas;
SELECT * FROM system.replication_queue;
SELECT *
FROM system.events
WHERE event LIKE '%Replicat%'
   OR event LIKE '%Network%';
```

Use `altinity-expert-clickhouse-replication` for the replication investigation.
Rack-aware Kafka fetching cannot reduce replica-to-replica transfer.

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
and repeat the broker-traffic comparison. A broker URL that differs from the
usual MSK listener port is not automatically wrong, but it warrants checking
against the cluster's current bootstrap-broker source of truth.

## Practical failure modes

- An exact-string mismatch fails silently; Kafka does not warn that rack-aware
  fetching was skipped.
- A correct rack value cannot compensate for a VPC endpoint that routes through
  another AZ.
- A gap between broker racks and ClickHouse racks may be intentional. Confirm
  compute placement before calling it a configuration defect.
- Check all ClickHouse pods in the namespace. An older or separate installation
  can make the traffic picture look inconsistent.
