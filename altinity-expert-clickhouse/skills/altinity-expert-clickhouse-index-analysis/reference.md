# Index analysis reference

Background material for `altinity-expert-clickhouse-index-analysis`. Read only
when you need to explain or justify a recommendation.

## ORDER BY design guidelines

1. **Lowest cardinality first.** The sparse primary index only skips granules
   while the leading columns still constrain the range, so a high-cardinality
   leading column leaves nothing to skip.
2. **Filtered columns belong in the key.** A column that appears in most WHERE
   clauses but not in the ORDER BY forces a full scan unless a skipping index or
   projection covers it.
3. **Time columns get reduced resolution.** `toDate(ts)` or `toStartOfHour(ts)`
   in the key gives range pruning without exploding cardinality. If the
   partition key already keys on time, the ORDER BY may not need it at all.
4. **The PRIMARY KEY may be a prefix of the ORDER BY.** Use that when the tail
   columns are needed for sorting or deduplication but not for filtering; it
   keeps the in-memory index smaller.

### Worked example

Given measured cardinalities `entity_type` 6, `entity` 18588 and `cast_hash`
335620, the ordering `(entity_type, entity, cast_hash, ...)` gives the most
granule skipping for queries that filter on any prefix of those columns.

## Common anti-patterns

| Anti-pattern | Problem | Fix |
|---|---|---|
| High-cardinality UUID first in ORDER BY | No granule skipping at all | Move it after the low-cardinality columns |
| `DateTime64` with sub-second precision first | Every granule has a distinct range | Use `toDate()` or `toStartOfHour()` |
| Column filtered in WHERE but absent from ORDER BY | Full scan | Add it to the ORDER BY, or add a projection |
| Bloom filter on a column that is an ORDER BY prefix | Redundant with the primary index | Drop the skipping index |
| Time neither in the ORDER BY nor in the partition key | Range queries scan every part | Add `toDate(ts)` to the ORDER BY prefix |

## Skipping index selection

A skipping index stores a summary per `granularity` granules and lets the reader
skip blocks whose summary cannot match.

Helps when:

- the column is not already covered by the ORDER BY prefix;
- the column's values correlate with the physical row order, so matching rows
  cluster into a few granules;
- the index type has a low false-positive rate for the predicate in use
  (`minmax` for ranges, `set` for small domains, `bloom_filter` and its
  token/ngram variants for equality and substring search).

Does not help when:

- the values are randomly distributed relative to the ORDER BY, so every granule
  contains a match;
- the cardinality is very high and the index is `set` or `bloom_filter`, which
  then approaches the size of the column itself;
- the predicate is a function of the column that the index expression does not
  match exactly.

## Projections

A projection is a second physical copy of the data with its own ORDER BY. It
removes the need to compromise on a single key, at the cost of duplicated
storage and merge work on every insert. Justify one from query frequency, not
from a single slow query.
