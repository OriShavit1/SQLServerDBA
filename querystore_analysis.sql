declare 
	@objname sysname = '%%'
	,@lastXmin int = 30

declare @offset int = DATEDIFF(hour,GETDATE(),GETUTCDATE())

select top 10
DATEADD(minute,-@lastXmin,DATEADD(hour,@offset,GETDATE())) last_exec_utc_filter
,isnull(max(object_name(q.object_id)),'') object_name
 ,min(rs.first_execution_time) first_execution_time_utc
,max(rs.last_execution_time) last_execution_time_utc
,sum(rs.count_executions) / NULLIF(DATEDIFF(second,min(rs.first_execution_time),max(rs.last_execution_time)),0) executions_per_second
,NULLIF(DATEDIFF(second,min(rs.first_execution_time),max(rs.last_execution_time)),0) sample_duration
,max(qt.query_sql_text) query_sql_text
,sum(rs.count_executions) count_executions
,COUNT(distinct p.plan_id) count_plans
,CAST(avg(1.0 * rs.avg_duration) / 1000.0 as bigint) avg_duration_ms
,CAST(sum(1.0 * rs.avg_duration * count_executions ) / 1000.0 as decimal(38,2) ) sum_duration_sec
,CAST(avg(1.0 * rs.avg_cpu_time) / 1000.0 as bigint) avg_cpu_time_ms
,CAST(sum(1.0 * rs.avg_cpu_time * count_executions ) /1000.0 / 1000.0 as decimal(38,2)) sum_cpu_time_sec
,CAST(avg(1.0 * rs.avg_clr_time) / 1000.0 as bigint) avg_clr_time_ms
,CAST(sum(1.0* rs.avg_clr_time * count_executions ) /1000.0/1000.0 as decimal(38,2)) sum_clr_time_sec
,CAST(avg(rs.avg_dop) AS INT) avg_dop
,CAST(avg(rs.avg_rowcount) as bigint) avg_rowcount 
,sum(rs.avg_rowcount * count_executions ) sum_rowcount
,CAST(avg(rs.avg_query_max_used_memory) * 8 as bigint) avg_query_max_used_memory_kb
,CAST(avg(rs.avg_logical_io_reads) * 8 as bigint) avg_logical_io_reads_kb
,CAST(avg(rs.avg_logical_io_writes) * 8 as bigint) avg_logical_io_writes_kb
,CAST(avg(rs.avg_physical_io_reads) * 8 as bigint) avg_physical_io_reads_kb
,CAST(avg(rs.avg_num_physical_io_reads) * 8 as bigint) avg_num_physical_io_reads_kb
,CAST(avg(rs.avg_log_bytes_used) * 1024 as bigint )avg_log_bytes_used_mb
,CAST(avg(rs.avg_tempdb_space_used) * 8 as bigint) avg_tempdb_space_used_kb
,CAST(sum(rs.avg_logical_io_reads * count_executions ) * 8 as bigint) sum_logical_io_reads_kb
,CAST(sum(rs.avg_logical_io_writes * count_executions ) * 8 as bigint) sum_logical_io_writes_kb
,CAST(sum(rs.avg_physical_io_reads * count_executions ) * 8 as bigint) sum_physical_io_reads_kb
,CAST(sum(rs.avg_query_max_used_memory * count_executions ) * 8 as bigint) sum_query_max_used_memory_kb
,CAST(sum(rs.avg_num_physical_io_reads * count_executions ) * 8 as bigint) sum_num_physical_io_reads_kb
,CAST(sum(rs.avg_log_bytes_used * count_executions ) * 1024 as bigint )sum_log_bytes_used_kb
,CAST(sum(rs.avg_tempdb_space_used * count_executions ) * 8 as bigint) sum_tempdb_space_used_kb

from sys.query_store_runtime_stats rs
join sys.query_store_plan p on p.plan_id = rs.plan_id
join sys.query_store_query q on q.query_id = p.query_id
join sys.query_store_query_text qt on qt.query_text_id = q.query_text_id

where 
rs.last_execution_time > DATEADD(minute,-@lastXmin,DATEADD(hour,@offset,GETDATE()))
and object_name(q.object_id) like @objname

group by q.query_id
order by sum_duration_sec desc
