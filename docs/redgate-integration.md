# Redgate SQL Monitor Integration

## Custom Metric
Use this query:
```sql
SELECT MetricValue = COUNT_BIG(1)
FROM IndexAdvisor.MissingIndexFindings f
WHERE f.IsSuppressed = 0
  AND f.IsAlerted   = 0
  AND f.ImpactScore >= 1000000
  AND f.LastSeenUtc >= DATEADD(hour, -6, SYSUTCDATETIME());
```
Set Warning ≥ 1, Critical ≥ 3 (tune to your estate). Poll every 5–15 minutes.

## Drill-down
Point dashboards to:
```sql
SELECT TOP (200) * 
FROM IndexAdvisor.vHighImpactMissingIndexDetails
ORDER BY ImpactScore DESC, LastSeenUtc DESC;
```
