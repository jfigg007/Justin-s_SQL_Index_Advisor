/*====================================================================
 Justin's SQL Index Advisor
 One-shot install script (schema, tables, funcs, views, procs)

 Target DB: DBA_Maint
 Requirements: SQL Server 2017+
====================================================================*/
IF DB_ID(N'DBA_Maint') IS NULL
BEGIN
    PRINT('Creating DBA_Maint...');
    EXEC('CREATE DATABASE DBA_Maint');
END
GO
USE DBA_Maint;
GO

/*====================================================================
 0) Schema
====================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'IndexAdvisor')
    EXEC('CREATE SCHEMA IndexAdvisor AUTHORIZATION dbo;');
GO

/*====================================================================
 1) Tables
====================================================================*/
IF OBJECT_ID(N'IndexAdvisor.MissingIndexFindings','U') IS NULL
BEGIN
    CREATE TABLE IndexAdvisor.MissingIndexFindings
    (
        FindingId            int IDENTITY(1,1) PRIMARY KEY,
        FirstSeenUtc         datetime2(3) NOT NULL,
        LastSeenUtc          datetime2(3) NOT NULL,

        DbId                 int       NOT NULL,
        DatabaseName         sysname   NOT NULL,
        SchemaName           sysname   NOT NULL,
        TableName            sysname   NOT NULL,

        EqualityColumns      nvarchar(max) NULL,
        InequalityColumns    nvarchar(max) NULL,
        IncludedColumns      nvarchar(max) NULL,

        UserSeeks            bigint    NOT NULL,
        UserScans            bigint    NOT NULL,
        AvgTotalUserCost     float     NOT NULL,
        AvgUserImpactPct     float     NOT NULL,
        ImpactScore          decimal(38,4) NOT NULL,

        Fingerprint          varbinary(32) NOT NULL UNIQUE,

        SuggestedCreateTsql  nvarchar(max) NULL,
        ImplementStatus      varchar(20) NOT NULL DEFAULT('PENDING'), -- PENDING|CREATE|SKIP|FAIL|DROP
        ImplementedIndexName sysname     NULL,
        ImplementedUtc       datetime2(3) NULL,
        CreateError          nvarchar(4000) NULL,

        IsSuppressed         bit NOT NULL DEFAULT(0),
        IsAlerted            bit NOT NULL DEFAULT(0),
        AlertNote            nvarchar(4000) NULL,

        ImpactBand AS (
            CASE
              WHEN ImpactScore >= 10000000 THEN 'CRITICAL'
              WHEN ImpactScore >= 1000000  THEN 'HIGH'
              WHEN ImpactScore >= 100000   THEN 'MEDIUM'
              WHEN ImpactScore >  0        THEN 'LOW'
              ELSE 'NONE'
            END
        ) PERSISTED
    );
END
GO

IF OBJECT_ID(N'IndexAdvisor.IndexImplementations','U') IS NOT NULL
    DROP TABLE IndexAdvisor.IndexImplementations;
GO
CREATE TABLE IndexAdvisor.IndexImplementations
(
    ImplId        bigint IDENTITY(1,1) PRIMARY KEY,
    EventUtc      datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
    Action        varchar(10)  NOT NULL,  -- CREATE|SKIP|FAIL|DROP
    DatabaseName  sysname      NOT NULL,
    SchemaName    sysname      NOT NULL,
    TableName     sysname      NOT NULL,
    IndexName     sysname      NULL,
    Reason        nvarchar(4000) NULL,
    CommandText   nvarchar(max) NULL,
    FindingId     int           NULL
);
GO

/*====================================================================
 2) Helper functions
====================================================================*/
CREATE OR ALTER FUNCTION IndexAdvisor.ufn_BuildIndexName
(
    @DatabaseName sysname,
    @SchemaName   sysname,
    @TableName    sysname,
    @Equality     nvarchar(max),
    @Inequality   nvarchar(max),
    @Includes     nvarchar(max)
)
RETURNS sysname
AS
BEGIN
    DECLARE @hash varbinary(32) =
        HASHBYTES('SHA2_256',
                  CONCAT(@DatabaseName,':',@SchemaName,':',@TableName,':',
                         ISNULL(@Equality,''),':',ISNULL(@Inequality,''),':',ISNULL(@Includes,'')));
    DECLARE @hex char(16) = CONVERT(char(16), CONVERT(varbinary(8), @hash), 2);
    RETURN CONCAT('IX_Avize_', @hex);  -- deterministic, short
END
GO

CREATE OR ALTER FUNCTION IndexAdvisor.ufn_BuildCreateIndexTsql
(
    @DatabaseName sysname,
    @SchemaName   sysname,
    @TableName    sysname,
    @Equality     nvarchar(max),     -- comma-separated cols without []
    @Inequality   nvarchar(max),     -- comma-separated cols without []
    @Includes     nvarchar(max),     -- comma-separated cols without []
    @Online       bit = 0,           -- 1 = WITH(ONLINE=ON), else omitted
    @FillFactor   int = 0,           -- 0 = omit
    @MaxDOP       int = 0            -- 0 = omit
)
RETURNS nvarchar(max)
AS
BEGIN
    DECLARE @idx sysname =
        IndexAdvisor.ufn_BuildIndexName(@DatabaseName,@SchemaName,@TableName,@Equality,@Inequality,@Includes);

    DECLARE @k1 nvarchar(max) = ISNULL(@Equality,'');
    DECLARE @k2 nvarchar(max) = ISNULL(@Inequality,'');
    DECLARE @keys nvarchar(max) =
        CASE WHEN @k1 <> '' AND @k2 <> '' THEN @k1 + ',' + @k2
             WHEN @k1 <> ''              THEN @k1
             ELSE @k2 END;

    DECLARE @inc  nvarchar(max) = CASE WHEN ISNULL(@Includes,'') <> '' THEN ' INCLUDE ('+@Includes+')' ELSE '' END;

    DECLARE @opt nvarchar(2000) = '';
    IF (@Online = 1 OR @FillFactor > 0 OR @MaxDOP > 0)
    BEGIN
        SET @opt = ' WITH (';
        IF @Online = 1      SET @opt += 'ONLINE = ON, ';
        IF @FillFactor > 0  SET @opt += 'FILLFACTOR = ' + CAST(@FillFactor AS varchar(5)) + ', ';
        IF @MaxDOP > 0      SET @opt += 'MAXDOP = ' + CAST(@MaxDOP AS varchar(5)) + ', ';
        -- trim trailing comma+space
        SET @opt = LEFT(@opt, LEN(@opt)-2) + ')';
    END

    DECLARE @sql nvarchar(max) = N'
USE ' + QUOTENAME(@DatabaseName) + N';
CREATE NONCLUSTERED INDEX ' + QUOTENAME(@idx) + N'
ON ' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName) + N' (' + @keys + N')' + @inc + @opt + N';';

    RETURN @sql;
END
GO

/*====================================================================
 3) Views
====================================================================*/
CREATE OR ALTER VIEW IndexAdvisor.vHighImpactMissingIndexDetails
AS
SELECT TOP (200)
    f.FindingId, f.FirstSeenUtc, f.LastSeenUtc,
    f.DatabaseName, f.SchemaName, f.TableName,
    f.ImpactBand, f.ImpactScore,
    f.UserSeeks, f.UserScans, f.AvgTotalUserCost, f.AvgUserImpactPct,
    f.EqualityColumns, f.InequalityColumns, f.IncludedColumns,
    f.SuggestedCreateTsql,
    f.ImplementStatus, f.ImplementedIndexName, f.ImplementedUtc,
    f.IsSuppressed, f.IsAlerted, f.AlertNote
FROM IndexAdvisor.MissingIndexFindings AS f
WHERE f.ImpactScore >= 1      -- raise to 100k/1M in prod
ORDER BY f.ImpactScore DESC, f.LastSeenUtc DESC;
GO

CREATE OR ALTER VIEW IndexAdvisor.vHighImpactMissingIndexMetric
AS
SELECT MetricValue = COUNT_BIG(1)
FROM IndexAdvisor.MissingIndexFindings f
WHERE f.IsSuppressed = 0
  AND f.IsAlerted   = 0
  AND f.ImpactScore >= 1000000           -- tune for your shop
  AND f.LastSeenUtc >= DATEADD(hour, -6, SYSUTCDATETIME());
GO

/*====================================================================
 4) Collector (per-DB batch; scoped name resolution)
====================================================================*/
CREATE OR ALTER PROCEDURE IndexAdvisor.usp_CollectMissingIndexes
      @MinSeeks           bigint        = 50
    , @MinImpactScore     decimal(38,4) = 100000
    , @IncludeReadOnlyDbs bit           = 0
    , @MaxPerDb           int           = 200
    , @TargetDb           sysname       = NULL   -- NULL = all user DBs; else only this DB
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @utcNow datetime2(3) = SYSUTCDATETIME();

    IF OBJECT_ID('tempdb..#Findings') IS NOT NULL DROP TABLE #Findings;
    CREATE TABLE #Findings
    (
        DbId              int            NOT NULL,
        DatabaseName      sysname        NOT NULL,
        SchemaName        sysname        NOT NULL,
        TableName         sysname        NOT NULL,
        EqualityColumns   nvarchar(max)  NULL,
        InequalityColumns nvarchar(max)  NULL,
        IncludedColumns   nvarchar(max)  NULL,
        UserSeeks         bigint         NOT NULL,
        UserScans         bigint         NOT NULL,
        AvgTotalUserCost  float          NOT NULL,
        AvgUserImpactPct  float          NOT NULL,
        ImpactScore       decimal(38,4)  NOT NULL,
        Fingerprint       varbinary(32)  NOT NULL
    );

    IF OBJECT_ID('tempdb..#DbList') IS NOT NULL DROP TABLE #DbList;
    SELECT d.name
    INTO   #DbList
    FROM   sys.databases AS d
    WHERE  d.state = 0
       AND d.database_id > 4
       AND (@IncludeReadOnlyDbs = 1 OR d.is_read_only = 0)
       AND (@TargetDb IS NULL OR d.name = @TargetDb);

    DECLARE @db  sysname, @sql nvarchar(max);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM #DbList;
    OPEN c; FETCH NEXT FROM c INTO @db;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
USE ' + QUOTENAME(@db) + N';
;WITH mi AS
(
    SELECT
        DbId              = DB_ID(),
        DatabaseName      = DB_NAME(),
        SchemaName        = OBJECT_SCHEMA_NAME(d.object_id, DB_ID()),
        TableName         = OBJECT_NAME(d.object_id, DB_ID()),
        EqualityColumns   = NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(d.equality_columns , ''['',''''), '']'',''''))), ''''),
        InequalityColumns = NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(d.inequality_columns, ''['',''''), '']'',''''))), ''''),
        IncludedColumns   = NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(d.included_columns , ''['',''''), '']'',''''))), ''''),
        UserSeeks         = gs.user_seeks,
        UserScans         = gs.user_scans,
        AvgTotalUserCost  = gs.avg_total_user_cost,
        AvgUserImpactPct  = gs.avg_user_impact,
        ImpactScore       = CAST(gs.avg_total_user_cost * (gs.avg_user_impact/100.0) * (gs.user_seeks + gs.user_scans) AS decimal(38,4))
    FROM sys.dm_db_missing_index_groups      AS g
    JOIN sys.dm_db_missing_index_group_stats AS gs ON g.index_group_handle = gs.group_handle
    JOIN sys.dm_db_missing_index_details     AS d  ON g.index_handle      = d.index_handle
    WHERE gs.user_seeks >= @MinSeeks
      AND d.database_id = DB_ID()
      AND d.object_id IS NOT NULL
)
SELECT TOP (@MaxPerDb)
       DbId, DatabaseName, SchemaName, TableName,
       EqualityColumns, InequalityColumns, IncludedColumns,
       UserSeeks, UserScans, AvgTotalUserCost, AvgUserImpactPct, ImpactScore,
       Fingerprint = HASHBYTES(''SHA2_256'',
                     CONCAT(DB_NAME(), '':'', SchemaName, '':'', TableName, '':'',
                            COALESCE(EqualityColumns, ''''), '':'',
                            COALESCE(InequalityColumns, ''''), '':'',
                            COALESCE(IncludedColumns, '''')))
FROM mi
WHERE SchemaName IS NOT NULL AND TableName IS NOT NULL
ORDER BY ImpactScore DESC;';

        BEGIN TRY
            INSERT INTO #Findings
            EXEC sys.sp_executesql
                 @sql,
                 N'@MinSeeks bigint, @MaxPerDb int',
                 @MinSeeks=@MinSeeks, @MaxPerDb=@MaxPerDb;
        END TRY
        BEGIN CATCH
            -- Optional: log per-DB errors here
        END CATCH;

        FETCH NEXT FROM c INTO @db;
    END
    CLOSE c; DEALLOCATE c;

    DECLARE @touched datetime2(3) = @utcNow;

    ;WITH src AS (SELECT * FROM #Findings WHERE ImpactScore >= @MinImpactScore)
    MERGE IndexAdvisor.MissingIndexFindings AS tgt
    USING src
       ON tgt.Fingerprint = src.Fingerprint
    WHEN MATCHED THEN UPDATE SET
         LastSeenUtc      = @touched,
         DbId             = src.DbId,
         DatabaseName     = src.DatabaseName,
         SchemaName       = src.SchemaName,
         TableName        = src.TableName,
         EqualityColumns  = src.EqualityColumns,
         InequalityColumns= src.InequalityColumns,
         IncludedColumns  = src.IncludedColumns,
         UserSeeks        = src.UserSeeks,
         UserScans        = src.UserScans,
         AvgTotalUserCost = src.AvgTotalUserCost,
         AvgUserImpactPct = src.AvgUserImpactPct,
         ImpactScore      = src.ImpactScore
    WHEN NOT MATCHED BY TARGET THEN
         INSERT (FirstSeenUtc, LastSeenUtc, DbId, DatabaseName, SchemaName, TableName,
                 EqualityColumns, InequalityColumns, IncludedColumns,
                 UserSeeks, UserScans, AvgTotalUserCost, AvgUserImpactPct,
                 ImpactScore, Fingerprint, SuggestedCreateTsql)
         VALUES (@touched, @touched, src.DbId, src.DatabaseName, src.SchemaName, src.TableName,
                 src.EqualityColumns, src.InequalityColumns, src.IncludedColumns,
                 src.UserSeeks, src.UserScans, src.AvgTotalUserCost, src.AvgUserImpactPct,
                 src.ImpactScore, src.Fingerprint,
                 IndexAdvisor.ufn_BuildCreateIndexTsql(src.DatabaseName, src.SchemaName, src.TableName,
                                                       src.EqualityColumns, src.InequalityColumns, src.IncludedColumns,
                                                       0, 0, 0)); -- Online omitted by default

    -- Refresh SuggestedCreateTsql for rows touched this run
    UPDATE f
      SET SuggestedCreateTsql =
            IndexAdvisor.ufn_BuildCreateIndexTsql(f.DatabaseName, f.SchemaName, f.TableName,
                                                  f.EqualityColumns, f.InequalityColumns, f.IncludedColumns,
                                                  0, 0, 0) -- Online omitted by default
    FROM IndexAdvisor.MissingIndexFindings AS f
    WHERE f.LastSeenUtc = @touched;

    -- Reset alert flags for fresh, unsuppressed items
    UPDATE f
      SET IsAlerted = 0, AlertNote = NULL
    FROM IndexAdvisor.MissingIndexFindings AS f
    WHERE f.IsSuppressed = 0
      AND f.LastSeenUtc = @touched
      AND f.ImpactScore >= @MinImpactScore;
END
GO

/*====================================================================
 5) Implementor (deterministic; WHATIF default; Online omitted by default)
====================================================================*/
CREATE OR ALTER PROCEDURE IndexAdvisor.usp_ImplementTopMissingIndexes
      @TopN            int            = 2
    , @ImpactThreshold decimal(38,4)  = 2000000
    , @WhatIf          bit            = 1
    , @Online          bit            = 0     -- default omit ONLINE
    , @FillFactor      int            = 0
    , @MaxDOP          int            = 0
    , @PrintCmds       bit            = 1
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH q AS
    (
        SELECT TOP (@TopN) *
        FROM IndexAdvisor.MissingIndexFindings
        WHERE ImpactScore >= @ImpactThreshold
          AND IsSuppressed = 0
        ORDER BY ImpactScore DESC, LastSeenUtc DESC
    )
    SELECT * INTO #todo FROM q;

    DECLARE @fid int, @db sysname, @sch sysname, @tbl sysname,
            @eq nvarchar(max), @iq nvarchar(max), @inc nvarchar(max),
            @idx sysname, @create nvarchar(max), @msg nvarchar(4000);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT FindingId, DatabaseName, SchemaName, TableName, EqualityColumns, InequalityColumns, IncludedColumns
        FROM #todo;

    OPEN c; FETCH NEXT FROM c INTO @fid, @db, @sch, @tbl, @eq, @iq, @inc;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @idx    = IndexAdvisor.ufn_BuildIndexName(@db,@sch,@tbl,@eq,@iq,@inc);
        SET @create = IndexAdvisor.ufn_BuildCreateIndexTsql(@db,@sch,@tbl,@eq,@iq,@inc, @Online,@FillFactor,@MaxDOP);

        -- Check existence by deterministic name in target DB
        DECLARE @exists int = 0;
        DECLARE @chk nvarchar(max) = N'USE ' + QUOTENAME(@db) + N';
SELECT @e = COUNT(*) 
FROM sys.indexes 
WHERE object_id = OBJECT_ID(N''' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl) + N''')
  AND name = ' + QUOTENAME(@idx, N'''') + N';';
        EXEC sp_executesql @chk, N'@e int OUTPUT', @e=@exists OUTPUT;

        IF @exists > 0
        BEGIN
            INSERT INTO IndexAdvisor.IndexImplementations(Action, DatabaseName, SchemaName, TableName, IndexName, Reason, CommandText, FindingId)
            VALUES ('SKIP', @db, @sch, @tbl, @idx, 'Already exists', @create, @fid);

            UPDATE IndexAdvisor.MissingIndexFindings
            SET ImplementStatus = 'SKIP', AlertNote = 'Already exists'
            WHERE FindingId = @fid;
        END
        ELSE
        BEGIN
            IF @PrintCmds = 1 PRINT @create;

            IF @WhatIf = 0
            BEGIN
                BEGIN TRY
                    EXEC (@create);
                    INSERT INTO IndexAdvisor.IndexImplementations(Action, DatabaseName, SchemaName, TableName, IndexName, Reason, CommandText, FindingId)
                    VALUES ('CREATE', @db, @sch, @tbl, @idx, NULL, @create, @fid);

                    UPDATE IndexAdvisor.MissingIndexFindings
                    SET ImplementStatus = 'CREATE', ImplementedIndexName = @idx, ImplementedUtc = SYSUTCDATETIME()
                    WHERE FindingId = @fid;
                END TRY
                BEGIN CATCH
                    SET @msg = ERROR_MESSAGE();
                    INSERT INTO IndexAdvisor.IndexImplementations(Action, DatabaseName, SchemaName, TableName, IndexName, Reason, CommandText, FindingId)
                    VALUES ('FAIL', @db, @sch, @tbl, @idx, @msg, @create, @fid);

                    UPDATE IndexAdvisor.MissingIndexFindings
                    SET ImplementStatus = 'FAIL', CreateError = @msg
                    WHERE FindingId = @fid;
                END CATCH
            END
            ELSE
            BEGIN
                INSERT INTO IndexAdvisor.IndexImplementations(Action, DatabaseName, SchemaName, TableName, IndexName, Reason, CommandText, FindingId)
                VALUES ('SKIP', @db, @sch, @tbl, @idx, 'WHATIF', @create, @fid);
            END
        END

        FETCH NEXT FROM c INTO @fid, @db, @sch, @tbl, @eq, @iq, @inc;
    END

    CLOSE c; DEALLOCATE c;
END
GO

/*====================================================================
 6) Tracker (usage sampling; optional auto-drop)
====================================================================*/
CREATE OR ALTER PROCEDURE IndexAdvisor.usp_TrackIndexUsage
      @ObserveHours     int = 24
    , @AutoDrop         bit = 0
    , @MinReadsToKeep   bigint = 50
    , @MaxWritesToKeep  bigint = 5000
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT FindingId, DatabaseName, SchemaName, TableName, ImplementedIndexName
        FROM IndexAdvisor.MissingIndexFindings
        WHERE ImplementStatus = 'CREATE'
          AND ImplementedIndexName IS NOT NULL;

    DECLARE @fid int, @db sysname, @sch sysname, @tbl sysname, @ix sysname;
    OPEN c; FETCH NEXT FROM c INTO @fid, @db, @sch, @tbl, @ix;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @reads bigint = 0, @writes bigint = 0;
        DECLARE @sql nvarchar(max) = N'
USE ' + QUOTENAME(@db) + N';
SELECT
    @reads_out  = ISNULL(us.user_seeks,0) + ISNULL(us.user_scans,0) + ISNULL(us.user_lookups,0),
    @writes_out = ISNULL(us.user_updates,0)
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats us
  ON us.object_id = i.object_id AND us.index_id = i.index_id AND us.database_id = DB_ID()
WHERE i.object_id = OBJECT_ID(''' + QUOTENAME(@sch) + '.' + QUOTENAME(@tbl) + N''')
  AND i.name = ' + QUOTENAME(@ix, N'''') + N';';

        EXEC sp_executesql @sql,
             N'@reads_out bigint OUTPUT, @writes_out bigint OUTPUT',
             @reads_out = @reads OUTPUT, @writes_out = @writes OUTPUT;

        UPDATE IndexAdvisor.MissingIndexFindings
        SET AlertNote = 'Reads=' + CAST(@reads AS varchar(50)) + ', Writes=' + CAST(@writes AS varchar(50))
                        + ' @ ' + CONVERT(varchar(19), SYSUTCDATETIME(), 126) + 'Z'
        WHERE FindingId = @fid;

        IF (@AutoDrop = 1 AND (@reads < @MinReadsToKeep AND @writes > @MaxWritesToKeep))
        BEGIN
            DECLARE @drop nvarchar(max) = N'USE ' + QUOTENAME(@db) + N';
DROP INDEX ' + QUOTENAME(@ix) + N' ON ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl) + N';';

            BEGIN TRY
                EXEC (@drop);
                INSERT INTO IndexAdvisor.IndexImplementations(Action, DatabaseName, SchemaName, TableName, IndexName, Reason, CommandText, FindingId)
                VALUES ('DROP', @db, @sch, @tbl, @ix, 'AutoDrop low-value index', @drop, @fid);

                UPDATE IndexAdvisor.MissingIndexFindings
                SET ImplementStatus = 'DROP', AlertNote = 'AutoDropped by tracker'
                WHERE FindingId = @fid;
            END TRY
            BEGIN CATCH
                INSERT INTO IndexAdvisor.IndexImplementations(Action, DatabaseName, SchemaName, TableName, IndexName, Reason, CommandText, FindingId)
                VALUES ('FAIL', @db, @sch, @tbl, @ix, ERROR_MESSAGE(), @drop, @fid);
            END CATCH
        END

        FETCH NEXT FROM c INTO @fid, @db, @sch, @tbl, @ix;
    END

    CLOSE c; DEALLOCATE c;
END
GO

/*====================================================================
 7) Smoke test (optional) — comment out in prod
====================================================================*/
-- EXEC IndexAdvisor.usp_CollectMissingIndexes
--      @TargetDb = N'tpcc',
--      @MinSeeks = 1,
--      @MinImpactScore = 1,
--      @MaxPerDb = 500;
-- SELECT TOP (20) * FROM IndexAdvisor.vHighImpactMissingIndexDetails ORDER BY ImpactScore DESC;
