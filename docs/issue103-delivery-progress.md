# Delivery with pending acceptance and append-only progress (#103)

Developer reports may explicitly set `delivery_complete=true` with `blocked` only
when implementation is complete and later acceptance lacks inputs. The original
conclusion is retained. Controller provenance, checkpoint, cleanup, authorization
and branch checks still precede draft PR delivery; review/validation stay gated.
Legacy blocked reports and contradictory `ready + false` reports do not deliver.

Claims remain immutable anchors. Meaningful facts enqueue persistent snapshots in
`claims.data` in business transactions. Ordered progress comments use distinct
event markers and POST only. Unknown sends require unique author/content readback;
they never replay or stop agent execution. Legacy PATCH intents reconcile read-only.
Confirmed events leave the queue; concurrent retry/queue changes merge transactionally.
Offline CLI uses real Git/OS isolation; real GitHub/model acceptance is NOT_RUN.
