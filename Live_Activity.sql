
	SELECT  GETDATE() lut,
			--con.client_net_address,
			conn.session_id ,
			conn.connect_time,
			conn.num_reads conn_total_reads,
			conn.num_writes conn_total_writes,
			conn.last_read conn_last_read,
			ses.host_name client_host_name,
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
			CASE 
				WHEN sqltext.objectid is not null AND dbid <> 32767 then OBJECT_NAME(objectid,dbid)
			ELSE sqltext.text END AS [text],
			sqltext.dbid,
			sqltext.objectid,
			req.blocking_session_id,
			req.command,
			req.cpu_time req_cpu_time,
			req.dop,
			req.granted_query_memory,
			req.logical_reads,
			req.last_wait_type,
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
			req.writes req_writes,
			seswaits.ses_tot_wait_duration_ms,
			spu.user_objects_alloc_page_count,
			spu.user_objects_dealloc_page_count,
			spu.internal_objects_alloc_page_count,
			spu.internal_objects_dealloc_page_count,
			spu.user_objects_deferred_dealloc_page_count,
			tran_log.tot_tran_log_record_count,
			tran_log.tot_tran_replication_log_record_count,
			tran_log.tot_log_bytes_used,
			tran_log.tot_log_bytes_reserved,
			tran_log.tot_log_bytes_used_system,
			tran_log.tot_log_bytes_reserved_system
	
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
	LEFT JOIN 
			(
		select 
				session_id
				,sum(database_transaction_log_record_count) tot_tran_log_record_count
				,sum(database_transaction_replicate_record_count) tot_tran_replication_log_record_count
				,sum(database_transaction_log_bytes_used) tot_log_bytes_used
				,sum(database_transaction_log_bytes_reserved) tot_log_bytes_reserved
				,sum(database_transaction_log_bytes_used_system) tot_log_bytes_used_system
				,sum(database_transaction_log_bytes_reserved_system) tot_log_bytes_reserved_system	
			from sys.dm_tran_session_transactions sestran 
			JOIN sys.dm_tran_database_transactions dbtran on dbtran.transaction_id = sestran.transaction_id--sestran.transaction_id
			group by session_id ) 
		AS tran_log 
		on tran_log.session_id = ses.session_id
	LEFT JOIN  (
		select 
				session_id,sum(wait_time_ms) ses_tot_wait_duration_ms 
			from sys.dm_exec_session_wait_stats
			group by session_id) 
		AS seswaits
		ON seswaits.session_id = tran_log.session_id
	LEFT JOIN sys.dm_db_session_space_usage spu on spu.session_id = ses.session_id 
	OUTER APPLY sys.dm_exec_sql_text(ISNULL(req.sql_handle,conn.most_recent_sql_handle)) as sqltext
	/*
	OUTER APPLY sys.dm_exec_query_plan(req.plan_handle) QP
	*/
	where 1=1 

	
	
