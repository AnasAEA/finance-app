# Design decisions

The app uses warm paper, forest green, readable money, and restrained status
colors. Each document records the reasoning and acceptance for a particular
slice; dated implementation notes should be read in that context.

| Document | Focus |
| --- | --- |
| [Experience overhaul](experience-overhaul.md) | App navigation and overall visual direction. |
| [Activity overhaul](activity-overhaul.md) | Readable history, pending disclosure, date groups, and efficient browsing. |
| [Activity categorization](activity-categorization.md) | Quick confirmation, approved merchant rules, and themed filters. |
| [Recorded-payment matching](recorded-payment-matching.md) | Conservative duplicate suggestions and explicit comparisons. |
| [Foreign-currency categorization](foreign-currency-categorization.md) | Exact account charges while retaining original provider evidence. |
| [Visual acceptance](visual-acceptance.md) | Interface acceptance expectations and evidence. |
| [Sync service audit](sync-service-audit.md) | Import correctness, service work, and operational efficiency. |

For current behavior, begin with the [README](../../README.md) and
[data and sync](../data-and-sync.md). Use the design records for implementation
rationale rather than as a release checklist.
