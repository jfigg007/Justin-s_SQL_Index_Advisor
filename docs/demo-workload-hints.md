# Demo Workload Hints

To generate sample missing index data for testing:

### Option 1: AdventureWorks
1. Restore `AdventureWorks2019.bak`.
2. Run analytic-style queries with missing predicates (no existing indexes).
3. Run collector:
   ```sql
   EXEC IndexAdvisor.usp_CollectMissingIndexes @TargetDb = N'AdventureWorks2019', @MinSeeks=1, @MinImpactScore=1;
   ```

### Option 2: HammerDB TPC-C
1. Install HammerDB.
2. Build schema for your SQL Server target (Warehouse = 10, Users = 1–5).
3. Run transactions for a few minutes.
4. Run collector:
   ```sql
   EXEC IndexAdvisor.usp_CollectMissingIndexes @TargetDb = N'tpcc';
   ```

You should now see high-impact missing indexes in:
```sql
SELECT * FROM IndexAdvisor.vHighImpactMissingIndexDetails ORDER BY ImpactScore DESC;
```
