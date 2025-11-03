# Architecture Overview

Justin's SQL Index Advisor is a lightweight DBA framework designed for SQL Server 2017+ that:
- Aggregates missing index recommendations (via DMVs)
- Persists findings across reboots (DMVs reset)
- Automates safe index creation with configurable thresholds
- Integrates with monitoring tools for alerting and visibility

### Components
| Component | Description |
|------------|-------------|
| Collector | Gathers and ranks missing indexes from DMVs across all user DBs. |
| Implementor | Creates indexes safely, respecting thresholds and avoiding duplicates. |
| Tracker | Observes usage stats and can auto-drop low-value indexes. |
| Views | Expose data for SQL Monitor and reporting dashboards. |

### Flow Diagram
```
[Workload] → [DMVs] → Collector → Findings Table → Implementor → IndexImplementations → Tracker → SQL Monitor Alert
```
