/*
Server Review by Ori Shavit
*/
SET NOCOUNT ON
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
/* 
Params for setting checks on/off
*/
DECLARE @ShowJobSchedules bit = 1
DECLARE @ShowProcStats bit = 1
DECLARE @ShowWarnings bit = 1
DECLARE @ShowAdvanceDB bit = 1
DECLARE @showMissingIndexes bit = 1
DECLARE @checkMissingBackups bit = 1 
/*
Params for customizing checks
*/
DECLARE @bak_alert int = 7; 
DECLARE @trn_alert int = 1;

/*
Script start
*/

DECLARE @starttime DATETIME = GETDATE()
DECLARE @checkpointprint NVARCHAR(256)

SELECT @starttime check_time

DROP TABLE IF EXISTS #configuration
CREATE TABLE #configuration (
  name nvarchar(256)  
    ,minimum bigint 
    ,maximum bigint   
    ,config_value bigint
    ,run_value bigint
)
DROP TABLE IF EXISTS #warnings
CREATE TABLE #warnings (
	category nvarchar(256)
	,warning nvarchar(256)
	,fix nvarchar(512)
	,note nvarchar(128)
)	
EXEC sp_configure 'show advanced options',1
RECONFIGURE WITH OVERRIDE

INSERT INTO #configuration 
	EXEC sp_configure
EXEC sp_configure 'show advanced options',0
RECONFIGURE WITH OVERRIDE


/*
Server information 
*/

DECLARE 
 @host_name nvarchar(256),
 @InstanceName nvarchar(256),
 @sql_name nvarchar(256),
 @editon nvarchar(256),
 @ProductLevel nvarchar(256),
 @ProductPatchLevel nvarchar(256),
 @SQLCollation sql_variant,
 @operating_system nvarchar(256),
 @SQLVersion sql_variant,
 @RegRootDir NVARCHAR(512)

SELECT 
 @sql_name = CONVERT(NVARCHAR,SERVERPROPERTY('ServerName'))
 ,@host_name = CONVERT(NVARCHAR,SERVERPROPERTY('MachineName'))
 ,@InstanceName = CONVERT(NVARCHAR,SERVERPROPERTY('InstanceName'))
 ,@editon = CONVERT(NVARCHAR,SERVERPROPERTY('Edition'))
 ,@ProductLevel = CONVERT(NVARCHAR,SERVERPROPERTY('ProductLevel'))
 ,@ProductPatchLevel = CONVERT(NVARCHAR,SERVERPROPERTY('ProductUpdateLevel'))
 ,@operating_system  = (select host_distribution from sys.dm_os_host_info)
 ,@SQLCollation = SERVERPROPERTY('Collation') 
 ,@SQLVersion = SERVERPROPERTY('ProductMajorVersion') 

IF NOT ((@host_name = @InstanceName) /*default instance*/
OR (@sql_name = (@host_name + '\' + @InstanceName))) /*named instance*/
INSERT INTO #warnings (warning, fix,note)
SELECT 'Mismatching Server Name!' AS Warning, 'select * from sys.servers' as fix, 'Expected: hostname\instance'

EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\Setup', N'SQLPath', @RegRootDir OUTPUT

SELECT 'Info - Host' as 'title'
	,@host_name [host_name], @operating_system operating_system
SELECT 'Info - SQL' as 'title' 
,@sql_name sql_name 
,CASE CAST (@SQLVersion AS INT)
	WHEN 15 THEN '2019'
	WHEN 14 THEN '2017'
	WHEN 13 THEN '2016'
	WHEN 12 THEN '2014'
	WHEN 11 THEN '2012'
	ElSE '???' END +' '+ @editon +' ' + @ProductLevel + ' ' + ISNULL(@ProductPatchLevel,'') edition 
	,@SQLCollation collation , @RegRootDir root_path,  @@VERSION full_version


/*
Memory Info
*/

DECLARE 
	@Host_Total_Memory INT = (SELECT (physical_memory_kb / 1024) FROM sys.dm_os_sys_info)
	,@Host_Free_Memory INT = (SELECT (available_physical_memory_kb / 1024.0 )from sys.dm_os_sys_memory)
	,@SQLUsedMemory_MB INT = (SELECT physical_memory_in_use_kb/1024 FROM sys.dm_os_process_memory)
	,@SQLMaxMemory_MB INT = (SELECT visible_target_kb/1024 FROM sys.dm_os_sys_info)
	,@CPUs INT = (SELECT cpu_count FROM sys.dm_os_sys_info)  
	,@SQL_used_cores INT = (SELECT COUNT(*) from sys.dm_os_schedulers where status = 'VISIBLE ONLINE') /*Cores actually usable by SQL*/

SELECT 'Hardware - Host' as 'title'
	,@Host_Total_Memory memory_MB
	,@Host_Free_Memory free_memory_MB
	,@CPUs CPUs
UNION
SELECT 'Hardware - SQL' as 'title'
	,@SQLMaxMemory_MB 
	,@SQLMaxMemory_MB - @SQLUsedMemory_MB  
	,@SQL_used_cores 


/* Compare CPU:TempDB Ratio */

DECLARE 
	@TempDBFiles int =  (
		select count(*) from tempdb.sys.database_files where type = 0 
	)
if (@CPUs > @TempDBFiles) and (@TempDBFiles < 8) 
INSERT INTO #warnings (category,warning,fix)
SELECT 'DB Setting','Not enough TempDB data files','Add some..'


/*
DB Sizes and Drives
*/

DROP TABLE IF EXISTS #db_files
CREATE TABLE #db_files (database_name SYSNAME, file_type SYSNAME, file_size_MB INT, unused_space_MB INT, drive CHAR(3))
DECLARE @SQL VARCHAR(512)= 'Use [?]'
+' INSERT INTO #db_files '
+' SELECT DB_NAME() AS database_name ,type_desc AS file_type, size/128 AS file_size_MB'
+', size/128 - CAST(FILEPROPERTY(name, ''SpaceUsed'') AS int)/128 AS unused_space_MB'
+', LEFT(physical_name,3 /*Assuming WinOS */) drive'
+' FROM sys.database_files '
+' WHERE DB_ID() > 4 OR DB_ID() = 2;'
exec sp_MSforeachdb @SQL

select 
	'SQL File Info' AS 'title'
	,drive
	,CASE WHEN database_name = 'tempdb' THEN 'tempdb' + ' ' + file_type 
		ELSE 'userdb' + ' ' + file_type END file_type
	,CAST(sum(file_size_MB)/1000.0 AS decimal(38,1)) allocated_GB,
	CAST(sum(unused_space_MB)/1000.0 AS decimal(38,1)) unused_GB
	,CAST(CAST(sum(unused_space_MB) AS decimal(38,1)) / sum(file_size_MB) * 100 AS INT) unused_percent
	,count(*) filecount
from #db_files data_files 
group by 
	drive
	,CASE WHEN database_name = 'tempdb' THEN 'tempdb' + ' ' + file_type 
		ELSE 'userdb' + ' ' + file_type END

SET @checkpointprint = 'Finished SQL File Info | Total Duration(ms): '+CAST(DATEDIFF(MILLISECOND,@starttime,GETDATE()) AS nvarchar)
RAISERROR (@checkpointprint,0,1) WITH NOWAIT	

/*
Global Traces 
*/

declare @traces table (flag int,status bit ,global bit ,session bit)
BEGIN TRY
	insert into @traces 
		exec ('DBCC TRACESTATUS(3266) WITH NO_INFOMSGS')
	insert into #warnings (category,warning,fix,note)
		SELECT 'Server Setting', 'Trace 3266 is not enabled', N'DBCC TRACEON (3266,-1)', 'No Reason to audit log backups in errorlog'
		from @traces where status = 0
END TRY
BEGIN CATCH PRINT(ERROR_MESSAGE()) END CATCH


/* 
View important configurations
*/

SELECT 'Advanced Server Option' as 'title' 
	,name, config_value, 
	case when run_value <> config_value then 'WARNING! Runing value is' + CAST(run_value AS NVARCHAR(128))  else 'Audit only' 
		end note
		, N'EXEC sys.sp_configure N'''+name+''' ,'+CAST(run_value AS nvarchar(1000))+N'; RECONFIGURE WITH OVERRIDE;' alter_cmd
from #configuration
	where
		run_value <> config_value
		or name like '%max degree of parallelism%'
		or name like 'cost threshold for parallelism'
		or name like '%ad hoc workloads%'
		or name like '%compression%'
		or name like '%trace%'

DECLARE 
	@dbname nvarchar(128) = '',
	@is_auto_close_on bit,
	@is_auto_update_stats_on bit,
	@is_query_store_on bit,
	@page_verify_option_desc NVARCHAR(128)
DECLARE 
	db_config CURSOR 
		FOR	SELECT QUOTENAME(name),is_auto_close_on,is_auto_update_stats_on,is_query_store_on,page_verify_option_desc FROM sys.databases 
		WHERE database_id > 4 /*ignore systemdb*/ and is_read_only = 0 and state = 0

IF @ShowAdvanceDB > 0
BEGIN
	DECLARE @advanceDB TABLE 
	(
		dbname NVARCHAR(128)
		,is_query_store_on bit
		,tuning_option_name NVARCHAR(128)
		,desired_state NVARCHAR(128)
		,actual_state NVARCHAR(128)
	)
	DECLARE @advanceCMD1 NVARCHAR(1000)
END
 
OPEN db_config
	WHILE (1=1)
	BEGIN
		FETCH NEXT from db_config into @dbname,@is_auto_close_on,@is_auto_update_stats_on,@is_query_store_on,@page_verify_option_desc
		IF @@FETCH_STATUS < 0 BREAK;
		IF @is_auto_update_stats_on = 0
			INSERT INTO #warnings (category,warning,fix,note)
				VALUES ('DB Setting', ('Database ' + @dbname + ' Automatic statistics off'),N'ALTER DATABASE ' + @dbname + N' SET AUTO_UPDATE_STATISTICS ON WITH NO_WAIT;', 'Most likely should be on')
		IF @page_verify_option_desc <> 'CHECKSUM'
			INSERT INTO #warnings (category,warning,fix,note)
				VALUES ('DB Setting', ('Database ' + @dbname + ' Page verification is '+@page_verify_option_desc), N'ALTER DATABASE '+ @dbname + N' SET PAGE_VERIFY CHECKSUM;' ,'Most reliable')
		IF @is_auto_close_on > 0
			INSERT INTO #warnings (category,warning, fix,note)
				VALUES ('DB Setting', ('Database ' + @dbname + ' is auto_close=ON'),N'ALTER DATABASE ' + @dbname + N' SET AUTO_CLOSE OFF WITH NO_WAIT;','Can cause issues')
		IF @ShowAdvanceDB > 0 AND  @is_query_store_on > 0
		BEGIN			
			SET @advanceCMD1 = N'SELECT '''+@dbname+N''', '+CAST(@is_query_store_on AS NVARCHAR)+N',ato.name,ato.desired_state_desc,actual_state_desc from '+@dbname+N'.sys.database_automatic_tuning_options ato where desired_state < 2'
			BEGIN TRY
				INSERT INTO @advanceDB
				EXEC (@advanceCMD1)
			END TRY
			BEGIN CATCH PRINT(ERROR_MESSAGE()) END CATCH
		END
	END
CLOSE db_config
DEALLOCATE db_config
SELECT 'Advanced DB Option' as title,* FROM @advanceDB

SET @checkpointprint = 'Finished Advanced DB Option | Total Duration(ms): '+CAST(DATEDIFF(MILLISECOND,@starttime,GETDATE()) AS nvarchar)
RAISERROR (@checkpointprint,0,1) WITH NOWAIT	
 
 
/* DB File growth */

DECLARE 
	@dbid int,
	@filename nvarchar(256)

DECLARE file_growth cursor for
 select database_id,name from sys.master_files
	where growth <> 8192

OPEN file_growth
FETCH NEXT from file_growth into @dbid,@filename

WHILE @@FETCH_STATUS = 0
BEGIN 
	INSERT INTO #warnings (category,warning,fix,note)
	VALUES ('File Growth', ('Database '+QUOTENAME(DB_NAME(@dbid)) +'  File growth is not 64MB '), 'ALTER DATABASE '+QUOTENAME(DB_NAME(@dbid)) +' MODIFY FILE ( NAME = N'''+ @filename+''', FILEGROWTH = 65536KB, MAXSIZE = UNLIMITED)', 'Best practice. Also sets unlimited size')
	FETCH NEXT FROM file_growth into @dbid,@filename
END
CLOSE file_growth
DEALLOCATE file_growth

/* 
CEIP Services (Sorry microsoft)
*/
IF EXISTS (
	SELECT * FROM sys.server_event_sessions
	WHERE name = 'telemetry_xevents')
BEGIN
	INSERT INTO #warnings (category,warning,fix,note)
	VALUES('Misc','CEIP Windows Service is running', 'DROP EVENT SESSION [telemetry_xevents] ON SERVER' , 'Also disable Windows Service to avoid errors')
END

/* Check for any active disaster recovery solution */


if exists (SELECT 1 from sys.availability_groups)
SELECT 
'Availability Groups' as 'title'
,ag.name group_name
,agrs.role_desc current_role
,health_check_timeout
,automated_backup_preference_desc
from sys.availability_groups ag
join sys.dm_hadr_availability_replica_states agrs on agrs.group_id = ag.group_id and agrs.is_local = 1
group by 
ag.name ,agrs.role_desc,health_check_timeout,automated_backup_preference_desc

if exists (select 1 from sys.database_mirroring where mirroring_state is NOT NULL)
SELECT 
'Mirroring Databases' as 'title'
,count(*) mirroring_databases, mirroring_role_desc
from sys.database_mirroring where mirroring_state is NOT NULL
group by mirroring_role_desc

if exists (select 1 from msdb.dbo.log_shipping_primary_databases)
SELECT 
'Log Shipping Databases' as 'title'
,count(*) log_shipping_primary_databases 
from msdb.dbo.log_shipping_primary_databases db1




IF @ShowJobSchedules > 0 BEGIN
/* Job schedules originally copied from dba.stackexchange.com/questions/148321 */
	select 'Job Schedules' AS 'title'
	       ,S.name AS jobname
		   ,S.enabled AS job_enabled
		   ,ISNULL(SS.enabled,0) AS schedule_enabled
		   ,ISNULL(SS.name,'Not found') AS schedule_name,
	       CASE(SS.freq_type)
	            WHEN 1  THEN 'Once'
	            WHEN 4  THEN 'Daily'
	            WHEN 8  THEN (case when (SS.freq_recurrence_factor > 1) then  'Every ' + convert(varchar(3),SS.freq_recurrence_factor) + ' Weeks'  else 'Weekly'  end)
	            WHEN 16 THEN (case when (SS.freq_recurrence_factor > 1) then  'Every ' + convert(varchar(3),SS.freq_recurrence_factor) + ' Months' else 'Monthly' end)
	            WHEN 32 THEN 'Every ' + convert(varchar(3),SS.freq_recurrence_factor) + ' Months' 
	            WHEN 64 THEN 'SQL Startup'
	            WHEN 128 THEN 'SQL Idle'
	            ELSE 'Not found'
	        END AS frequency,
	       ISNULL(CASE
	            WHEN (freq_type = 1)                       then 'One time only'
	            WHEN (freq_type = 4 and freq_interval = 1) then 'Every Day'
	            WHEN (freq_type = 4 and freq_interval > 1) then 'Every ' + convert(varchar(10),freq_interval) + ' Days'
	            WHEN (freq_type = 8) then (select 'Weekly Schedule' = MIN(D1+ D2+D3+D4+D5+D6+D7 )
	                                        from (select SS.schedule_id,
	                                                        freq_interval,
	                                                        'D1' = CASE WHEN (freq_interval & 1  <> 0) then 'Sun ' ELSE '' END,
	                                                        'D2' = CASE WHEN (freq_interval & 2  <> 0) then 'Mon '  ELSE '' END,
	                                                        'D3' = CASE WHEN (freq_interval & 4  <> 0) then 'Tue '  ELSE '' END,
	                                                        'D4' = CASE WHEN (freq_interval & 8  <> 0) then 'Wed '  ELSE '' END,
	                                                    'D5' = CASE WHEN (freq_interval & 16 <> 0) then 'Thu '  ELSE '' END,
	                                                        'D6' = CASE WHEN (freq_interval & 32 <> 0) then 'Fri '  ELSE '' END,
	                                                        'D7' = CASE WHEN (freq_interval & 64 <> 0) then 'Sat '  ELSE '' END
	                                                    from msdb..sysschedules ss
	                                                where freq_type = 8
	                                            ) as F
	                                        where schedule_id = SJ.schedule_id
	                                    )
	            WHEN (freq_type = 16) then 'Day ' + convert(varchar(2),freq_interval)
	            WHEN (freq_type = 32) then (select  freq_rel + WDAY
	                                        from (select SS.schedule_id,
	                                                        'freq_rel' = CASE(freq_relative_interval)
	                                                                    WHEN 1 then 'First'
	                                                                    WHEN 2 then 'Second'
	                                                                    WHEN 4 then 'Third'
	                                                                    WHEN 8 then 'Fourth'
	                                                                    WHEN 16 then 'Last'
	                                                                    ELSE '??'
	                                                                    END,
	                                                    'WDAY'     = CASE (freq_interval)
	                                                                    WHEN 1 then ' Sun'
	                                                                    WHEN 2 then ' Mon'
	                                                                    WHEN 3 then ' Tue'
	                                                                    WHEN 4 then ' Wed'
	                                                                    WHEN 5 then ' Thu'
	                                                                    WHEN 6 then ' Fri'
	                                                                    WHEN 7 then ' Sat'
	                                                                    WHEN 8 then ' Day'
	                                                                    WHEN 9 then ' Weekday'
	                                                                    WHEN 10 then ' Weekend'
	                                                                    ELSE '??'
	                                                                    END
	                                                from msdb..sysschedules SS
	                                                where SS.freq_type = 32
	                                                ) as WS 
	                                        where WS.schedule_id = SS.schedule_id
	                                        ) 
	        END,'Not found') AS interval,
	        CASE (freq_subday_type)
	            WHEN 1 then   left(stuff((stuff((replicate('0', 6 - len(active_start_time)))+ convert(varchar(6),active_start_time),3,0,':')),6,0,':'),8)
	            WHEN 2 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' seconds'
	            WHEN 4 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' minutes'
	            WHEN 8 then 'Every ' + convert(varchar(10),freq_subday_interval) + ' hours'
	            ELSE 'Not found'
	        END AS [time],
	        ISNULL(CASE SJ.next_run_date
	            WHEN 0 THEN cast('Not found' as char(10))
	            ELSE convert(char(10), convert(datetime, convert(char(8),SJ.next_run_date)),120)  + ' ' + left(stuff((stuff((replicate('0', 6 - len(next_run_time)))+ convert(varchar(6),next_run_time),3,0,':')),6,0,':'),8)
	        END,'Not found') AS next_runtime,
			ISNULL(failed.cnt,0) fails_in_hist
	from msdb.dbo.sysjobs S
	left join msdb.dbo.sysjobschedules SJ on S.job_id = SJ.job_id  
	left join msdb.dbo.sysschedules SS on SS.schedule_id = SJ.schedule_id
	left join (
		select H.job_id,count(*) cnt from msdb.dbo.sysjobhistory H
		where H.run_status = 0
		group by H.job_id
	) failed on failed.job_id = S.job_id
	order by jobname

	SET @checkpointprint = 'Finished Job Schedules| Total Duration(ms): '+CAST(DATEDIFF(MILLISECOND,@starttime,GETDATE()) AS nvarchar)
	RAISERROR (@checkpointprint,0,1) WITH NOWAIT	
END

IF @checkMissingBackups > 0
BEGIN

	DROP TABLE IF EXISTS #backupcheck
	CREATE TABLE #backupcheck(
		name sysname NULL,
		recovery_model_desc nvarchar(60) NULL,
		last_full_backup datetime NULL,
		last_log_backup datetime NULL,
		bak_path nvarchar(260) NULL,
		trn_path nvarchar(260) NULL,
		warning varchar(50) NOT NULL
	) 
	INSERT INTO #backupcheck
	select db.name,db.recovery_model_desc , fulls.last_full_backup, logs.last_log_backup, fulls.bak_path, logs.trn_path
	,ISNULL(CASE
	WHEN ISNULL(DATEDIFF(day,fulls.last_full_backup,GETDATE()),999) > @bak_alert 
		THEN 'No FULL-backup recently ' END,'')
	+ ISNULL(CASE 
	WHEN db.recovery_model < 3 AND ( ISNULL(DATEDIFF(day,logs.last_log_backup,GETDATE()),999) > @trn_alert ) 
		THEN 'No LOG-backup recently' END,'') AS warning
	FROM sys.databases db
	left join 
		(
		select  bs.database_name, max(bs.backup_finish_date) last_full_backup, max(bmf.physical_device_name) bak_path
		FROM msdb.dbo.backupset bs 
		LEFT OUTER JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
			WHERE type = 'D' and is_copy_only = 0
				AND bs.backup_finish_date > DATEADD(DAY, -@bak_alert, GETDATE())
			group by bs.database_name
		) fulls on fulls.database_name = db.name
	left join 
		(
		select  bs.database_name, max(bs.backup_finish_date) last_log_backup, max(bmf.physical_device_name) trn_path
		FROM msdb.dbo.backupset bs 
		LEFT OUTER JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
			WHERE type = 'L' and is_copy_only = 0
				AND bs.backup_finish_date > DATEADD(DAY, -@trn_alert, GETDATE())
			group by bs.database_name
		) logs
	on logs.database_name = db.name and db.recovery_model < 3
	
	where 
		db.is_read_only = 0 
		and db.state = 0 
		and db.database_id <>2
	;
	INSERT INTO #warnings(category,warning,fix,note)
	SELECT 'Missing Backups', 'Database '+ QUOTENAME(name) + ' ' + warning, 'Make backups', 'Thresholds: full: '+CAST(@bak_alert AS NVARCHAR)+'d, log: '+CAST(@trn_alert AS NVARCHAR)+'d' from #backupcheck where warning > '' 
	SET @checkpointprint = 'Finished Missing Backups | Total Duration(ms): '+CAST(DATEDIFF(MILLISECOND,@starttime,GETDATE()) AS nvarchar)
	RAISERROR (@checkpointprint,0,1) WITH NOWAIT	
END

IF @ShowProcStats > 0
BEGIN
	select top 20
	'Proc Stats' AS 'title'
	,DB_NAME(PS.database_id) dbname
	,OBJECT_NAME(PS.object_id,PS.database_id) procname
	,sum(PS.total_elapsed_time) / sum(PS.execution_count) / 1000 avg_runtime_ms
	,sum(PS.total_worker_time) / sum(PS.execution_count) / 1000 avg_cpu_ms
	,max(PS.total_elapsed_time)/1000 max_runtime_ms
	,max(PS.total_worker_time)/1000 max_cpu_ms
	,sum(PS.execution_count) execution_count 
	,count(*) diff_plans
	     FROM sys.dm_exec_procedure_stats AS PS
		 where PS.database_id not in (32767,1,2,3,4)
	group by PS.object_id,PS.database_id
	order by avg_runtime_ms desc

	SET @checkpointprint = 'Finished Proc Stats | Total Duration(ms): '+CAST(DATEDIFF(MILLISECOND,@starttime,GETDATE()) AS nvarchar)
	RAISERROR (@checkpointprint,0,1) WITH NOWAIT	

END

IF @showMissingIndexes > 0
BEGIN
	SELECT 'Missing Indexes' AS 'title',
	mid.statement [objectname],mid.equality_columns
	,avg(migs.avg_user_impact ) avg_user_impact
	,CONVERT (decimal (28, 1), avg(migs.avg_total_user_cost) * avg(migs.avg_user_impact ) * (sum(migs.user_seeks + migs.user_scans)) ) total_improvement_measure
	,count(*) diff_recommendations
	FROM sys.dm_db_missing_index_groups mig
	INNER JOIN sys.dm_db_missing_index_group_stats migs ON migs.group_handle = mig.index_group_handle
	INNER JOIN sys.dm_db_missing_index_details mid ON mig.index_handle = mid.index_handle
	WHERE 
		CONVERT(decimal (28, 1),migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans)) > 10
	group by mid.statement,mid.equality_columns
	order by total_improvement_measure desc
	
	SET @checkpointprint = 'Finished Missing Indexes | Total Duration(ms): '+CAST(DATEDIFF(MILLISECOND,@starttime,GETDATE()) AS nvarchar)
	RAISERROR (@checkpointprint,0,1) WITH NOWAIT	
END

IF @ShowWarnings > 0
BEGIN
	SELECT 'WorkToDo' as 'title' ,* FROM #warnings
END

SET @checkpointprint = 'Finished ALL - | Total Duration(Seconds): '+CAST(DATEDIFF(SECOND,@starttime,GETDATE()) AS nvarchar)
RAISERROR (@checkpointprint,0,1) WITH NOWAIT
