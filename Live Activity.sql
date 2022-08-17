SELECT
--con.client_net_address,
conn.session_id ,
conn.connect_time,
conn.num_reads conn_total_reads,
conn.num_writes conn_total_writes,
conn.last_read conn_last_read,
ses.host_name,
ses.program_name,
ses.host_process_id,
ses.is_user_process,
ses.client_interface_name,
ses.login_name,
ses.status session_status,
ses.cpu_time ses_cpu_time,
ses.total_scheduled_time ses_total_scheduled_time,
ses.total_elapsed_time ses_total_elapsed_time,
ses.last_request_start_time,
ses.last_request_end_time,
ses.reads ses_reads,
ses.logical_reads ses_logical_reads,
ses.writes ses_writes,
ses.database_id,
spu.user_objects_alloc_page_count,
spu.user_objects_dealloc_page_count,
spu.internal_objects_alloc_page_count,
spu.internal_objects_dealloc_page_count,
spu.user_objects_deferred_dealloc_page_count,
ISNULL(RST.dbid,CST.dbid) sql_dbid,
ISNULL(RST.objectid,CST.objectid) sql_objectid,
ISNULL(RST.text,CST.text) sql_text,
req.blocking_session_id,
req.command,
req.cpu_time req_cpu_time,
req.dop,
req.granted_query_memory,
req.last_wait_type,
req.logical_reads,
req.open_transaction_count,
req.parallel_worker_count,
req.percent_complete,
req.query_hash,
req.query_plan_hash,
req.reads,
req.request_id,
req.row_count,
req.statement_end_offset,
req.statement_start_offset,
req.start_time req_start_time,
req.status req_status,
req.total_elapsed_time req_total_elapsed_time,
req.wait_resource,
req.wait_time req_wait_time,
req.wait_type req_wait_type,
req.writes req_writes

/*
SUBSTRING(CST.text, (req.statement_start_offset/2) + 1,  
    ((CASE statement_end_offset   
        WHEN -1 THEN DATALENGTH(CST.text)  
        ELSE req.statement_end_offset END   
            - req.statement_start_offset)/2) + 1) 
			AS current_statement

			*/
FROM sys.dm_exec_connections conn
JOIN sys.dm_exec_sessions ses on ses.session_id = conn.session_id
JOIN sys.dm_exec_requests req on req.session_id = conn.session_id
LEFT JOIN sys.dm_db_session_space_usage spu on spu.session_id = ses.session_id 
/*
LEFT JOIN sys.dm_tran_session_transactions sestran on sestran.session_id = ses.session_id
LEFT JOIN sys.dm_tran_database_transactions dbtran on dbtran.transaction_id = req.transaction_id--sestran.transaction_id
*/
OUTER APPLY sys.dm_exec_sql_text(conn.most_recent_sql_handle) as CST
OUTER APPLY sys.dm_exec_sql_text(req.sql_handle) as RST
/*
OUTER APPLY sys.dm_exec_query_plan(req.plan_handle) QP
*/
where 1=1 
--and req.session_id is not null
--dbtran.transaction_id is not null
and conn.most_recent_sql_handle <> req.sql_handle
GO


