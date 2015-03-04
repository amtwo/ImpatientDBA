USE master
GO
--We don't want to drop/create this guy once we mark it as system
--it is believed to be the root of problems with DBCore in the past
--Instead, create a stub & grant permissions if it doesn't exist, then alter the sproc to use the correct code.
IF OBJECT_ID('sp_helpindex3', 'P') IS  NULL
BEGIN
	--do this in dynamic SQL so CREATE PROCEDURE can be nested in this IF block
	EXEC ('CREATE PROCEDURE dbo.sp_helpindex3 AS SELECT 1')
	--mark it as a system object
	EXEC sp_MS_marksystemobject sp_helpindex3
	--grant permission to the whole world
	GRANT EXECUTE ON sp_helpindex3 to PUBLIC
END
GO

--Now do an alter
ALTER PROCEDURE dbo.sp_helpindex3
@objname NVARCHAR(776) = NULL
AS 
SET NOCOUNT ON
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 2012-Sept
	Branched from sp_helpindex3 downloaded from here: 
		http://realsqlguy.blogspot.com/2008/04/include-columns-and-sphelpindex.html
		Blog is now defunct
	Give me more index information about this table like included columns,
PARAMETERS:
	@objname - Name of table or view for which to return index info 
		Use dot notion of Object or schema.object or database.schema.object
EXAMPLES:
* Show index information for internal_tracking.dbo.Monitor_TracePermanent:
	EXEC sp_helpindex3 'internal_tracking.dbo.monitor_tracepermanent'
**************************************************************************************************
MODIFICATIONS:
	20120921 - AM2: Change ind_cur to do OUTER apply, rather than CROSS apply. Just in case no Usage stats.
	20120921 - AM2 - make cursor dynamic sql to allow lookup of indexes in other DBs
					- call sp_get_base_table to get base table name, in case @objname is a view or syn
	20121101 - AM2 - Reformat this header to standard format
					- add data compression to output. Required added join to sys.partitions.
	20121108 - AM2 - Add output columns with text for compressing (PAGE) the index 
					& estimating space savings from compression
	20130624 - AM2 - Refactor code... Add #Tables temp table to hold object(s) we want to 
			analyze indices on. 
			- Update code so you can get all tables for a specific database
			- Update code so you can wildcard schema or table name
	20130910 - AM2 - Add column to include "CREATE INDEX" statement
	20140228 - AM2 - Update to use sp_get_basetable_list, which is more flexible than my old
					sp_get_base_table
	20140304 - AM2 - Cleanup formatting, variable names
				- Remove the code to change fillfactors. We never use it.
	2014-09-24 - AM2 - Fix for collation
**************************************************************************************************
To do:
* Right now we ignore indexes on schemabound views. We should probably handle those.
* CREATE text for PKs should probably be special
**************************************************************************************************
	This code is free to download and use for personal, educational, and internal 
	corporate purposes, provided that this header is preserved. Redistribution or sale, 
	in whole or in part, is prohibited without the author's express written consent.
*************************************************************************************************/
DECLARE
	@objid				int, -- the object id of the table
	@indid				smallint, -- the index id of an index
	@groupid			int, -- the filegroup id of an index
	@indname			sysname,
	@groupname			sysname,
	@status				int,
	@keys				nvarchar(2126), --Length (16*max_identifierLength)+(15*2)+(16*3)
	@include_cols		nvarchar(2126),
	@dbname				sysname,
	@ignore_dup_key		bit,
	@is_unique			bit,
	@filter_definition	nvarchar(max),
	@is_hypothetical	bit,
	@is_primary_key		bit,
	@is_unique_key		bit,
	@auto_created		bit,
	@no_recompute		bit,
	@data_compression_desc	nvarchar(120), 
	@last_user_seek		datetime,
	@last_user_scan		datetime,
	@last_user_lookup	datetime,
	@last_user_update	datetime,
	@user_seeks			bigint,
	@user_scans			bigint,
	@user_lookups		bigint,
	@user_updates		bigint,
	@orig_fillfactor	int,
	@index_size_mb      decimal(10,3),
	@sql				nvarchar(2000),
	@baseobjname		nvarchar(776);

--
-- STEP 1
--
-- Create & populate #tables with the object(s) we want index info for
--    Yes, I call it #tables, but it might contain views or synonyms
--
CREATE TABLE #tables (DbName sysname COLLATE database_default, 
			SchemaName sysname COLLATE database_default, 
			TableName sysname COLLATE database_default, 
			ObjType char(2) COLLATE database_default
			CONSTRAINT pk_tables PRIMARY KEY (DbName, SchemaName, TableName))

IF COALESCE(@objname,'') = ''
-- No object passed.  We'll do all user tables in the current database
BEGIN
	INSERT INTO #tables (DbName, SchemaName, TableName)
	SELECT db_name(), schema_name(schema_id), name
	FROM sys.objects
	WHERE type = 'U'
	AND is_ms_shipped = 0
END
ELSE IF CHARINDEX('%', @objname) = 0
-- specific object passed, no wildcards
BEGIN
	INSERT INTO #tables (DbName, SchemaName, TableName)
	SELECT COALESCE(parsename(@objname,3),db_name()),
		COALESCE(parsename(@objname,2),schema_name()),
	parsename(@objname,1)
END
ELSE IF CHARINDEX('%',@objname) > 0
-- a string was passed, but with wildcards. Only support wildcard on schema & table. 
BEGIN
	--throw an error if % is part of DbName
	IF CHARINDEX('%',parsename(@objname,3)) > 0
		RAISERROR('Cannot pass wildcard in database name.',16,1)
	-- if the wildcard is in the schema or table name its easy to handle. queue dynamic sql
	SET @sql = 'INSERT INTO #tables (DbName, SchemaName, TableName) '
		+ 'SELECT ''' + COALESCE(parsename(@objname,3),db_name()) + ''', '
		+ 'schema_name(schema_id), name '
		+ 'FROM [' + COALESCE(parsename(@objname,3),db_name()) + '].sys.objects '
		+ 'WHERE type = ''U'' AND schema_name(schema_id) LIKE ''' 
		+ COALESCE(parsename(@objname,2),schema_name()) + ''' AND name like ''' 
		+ parsename(@objname,1) + ''''
	EXEC (@sql)
END

--Now that we populated #tables, call sp_get_basetable_list
-- This will magically turn views & synonyms into their physical tables
EXEC sp_get_basetable_list

--
-- STEP 2
--
-- Now loop through them all & gather the details
--

--cursor definition
DECLARE tbl_cur CURSOR FOR
SELECT QUOTENAME(DbName) + '.' + QUOTENAME(SchemaName) + '.' + QUOTENAME(TableName) AS ObjectName
FROM #tables

--some temp tables we'll need for the cursor

-- This temp table gets used inside the loop. It gets truncated each loop through the cursor
CREATE TABLE #table_indexes
	(
	index_name			sysname COLLATE database_default	NOT NULL,
	index_id			int,
	ignore_dup_key		bit,
	is_unique			bit,
	filter_definition	nvarchar(max) COLLATE database_default,
	is_hypothetical		bit,
	is_primary_key		bit,
	is_unique_key		bit,
	auto_created		bit,
	no_recompute		bit,
	data_compression_desc	nvarchar(120) COLLATE database_default,
	index_size_mb       decimal(10,3),
	groupname			sysname COLLATE database_default NULL,
	index_keys			nvarchar(2126) COLLATE database_default	NOT NULL,
	includes			nvarchar(2126) COLLATE database_default	NOT NULL,
	last_user_seek		datetime,
	last_user_scan		datetime,
	last_user_lookup	datetime,
	last_user_update	datetime,
	user_seeks			bigint,
	user_scans			bigint,
	user_lookups		bigint,
	user_updates		bigint,
	orig_fillfactor		int
	)

-- If the name wasn't obvious, we use this table to build the final resultset
CREATE TABLE #Results (
	table_name			nvarchar(776) COLLATE database_default,
	index_name			sysname COLLATE database_default,
	index_id			int,
	orig_fillfactor		int,
	index_description	varchar(210) COLLATE database_default,
	index_keys			nvarchar(2126) COLLATE database_default,
	include_cols		nvarchar(2126) COLLATE database_default,
	filter_definition	nvarchar(MAX) COLLATE database_default,
	compression_desc	nvarchar(120) COLLATE database_default,
	index_size_mb       decimal(10,3),
	last_user_seek		datetime,
	last_user_scan		datetime,
	last_user_lookup	datetime,
	last_user_update	datetime,
	user_seeks			bigint,
	user_scans			bigint,
	user_lookups		bigint,
	user_updates		bigint,
	create_text			nvarchar(max) COLLATE database_default,
	rebuild_text		nvarchar(max) COLLATE database_default,
	reorganize_text		nvarchar(max) COLLATE database_default,
	drop_text			nvarchar(max) COLLATE database_default,
	compress_text		nvarchar(max) COLLATE database_default,
	est_compression_savings_text	nvarchar(max) COLLATE database_default
	)

OPEN tbl_cur
FETCH NEXT FROM tbl_cur INTO @objname -- this is 3-part dotted object name.

WHILE @@FETCH_STATUS = 0
BEGIN
	-- initialize this temp table
	TRUNCATE TABLE #table_indexes
	
	-- Grab the DB Name from @objname
	SELECT @dbname = PARSENAME(@objname, 3)

	-- SANITY CHECK: Check to see the the table exists and initialize @objid.
	-- The table should always exist. Call to sp_get_basetable_list took care of that. 
	SELECT @objid = OBJECT_ID(@objname)
	IF @objid IS NULL
	BEGIN
		RAISERROR(15009,-1,-1,@objname,@dbname)
		RETURN (1)
	END


	-- OPEN CURSOR OVER INDEXES 
	-- dynamic SQL because the DB name could be anything
	SET @sql = N'DECLARE ind_cur CURSOR GLOBAL FOR
	SELECT
	i.index_id,
	i.data_space_id,
	i.name,
	i.ignore_dup_key,
	i.is_unique,
	i.filter_definition,
	i.is_hypothetical,
	i.is_primary_key,
	i.is_unique_constraint,
	s.auto_created,
	s.no_recompute,
	p.data_compression_desc,
	iu.last_user_seek,
	iu.last_user_scan,
	iu.last_user_lookup,
	iu.last_user_update,
	iu.user_seeks,
	iu.user_scans,
	iu.user_lookups,
	iu.user_updates,
	i.fill_factor,
	(SELECT SUM(au.used_pages)*8/1024.0 FROM ' + @dbname + '.sys.allocation_units AS au 
		WHERE au.container_id = p.partition_id) AS index_size_mb
	FROM ' + @dbname + '.sys.indexes i
	JOIN ' + @dbname + '.sys.stats s ON i.OBJECT_ID = s.OBJECT_ID AND i.index_id = s.stats_id
	JOIN ' + @dbname + '.sys.partitions p ON i.OBJECT_ID = p.OBJECT_ID AND i.index_id = p.index_id
	OUTER APPLY ( SELECT
			MAX(ius.last_user_seek) AS last_user_seek,
			MAX(ius.last_user_scan) AS last_user_scan,
			MAX(ius.last_user_lookup) AS last_user_lookup,
			MAX(ius.last_user_update) AS last_user_update,
			SUM(ISNULL(ius.user_seeks, 0)) AS user_seeks,
			SUM(ISNULL(ius.user_scans, 0)) AS user_scans,
			SUM(ISNULL(ius.user_lookups, 0)) AS user_lookups,
			SUM(ISNULL(ius.user_updates, 0)) AS user_updates
			FROM ' + @dbname + '.sys.dm_db_index_usage_stats AS ius
			WHERE i.index_id = ius.index_id
			AND ius.object_id = i.object_id
			GROUP BY ius.object_id,	ius.index_id
		) AS iu
	WHERE i.OBJECT_ID = ' + CAST(@objid as nvarchar)

	--PRINT @sql
	EXEC (@sql)

	OPEN ind_cur
	FETCH ind_cur INTO @indid, @groupid, @indname, @ignore_dup_key,
	@is_unique, @filter_definition, @is_hypothetical, @is_primary_key, @is_unique_key,
	@auto_created, @no_recompute, @data_compression_desc, @last_user_seek, @last_user_scan,
	@last_user_lookup, @last_user_update, @user_seeks, @user_scans,
	@user_lookups, @user_updates, @orig_fillfactor, @index_size_mb ;

	
	-- Loop through indexes to get info about them for #Results
	WHILE @@fetch_status >= 0
	BEGIN
		-- First we'll figure out what the keys are.
		DECLARE @i INT,
				@thiskey NVARCHAR(131) -- 128+3
	
		SELECT @keys = INDEX_COL(@objname, @indid, 1), @i = 2
	
		IF ( INDEXKEY_PROPERTY(@objid, @indid, 1, 'isdescending') = 1 )
			SELECT @keys = @keys + '(-)'
	
		SELECT @thiskey = INDEX_COL(@objname, @indid, @i)
	
		IF ( (@thiskey IS NOT NULL) AND ( INDEXKEY_PROPERTY(@objid, @indid, @i, 'isdescending') = 1 ) )
			SELECT @thiskey = @thiskey + '(-)'
	
		WHILE ( @thiskey IS NOT NULL )
		BEGIN
			SELECT @keys = @keys + ', ' + @thiskey,
					@i = @i + 1
			SELECT @thiskey = INDEX_COL(@objname, @indid, @i)
			IF ( (@thiskey IS NOT NULL) AND ( INDEXKEY_PROPERTY(@objid, @indid, @i,'isdescending') = 1 ) )
				SELECT @thiskey = @thiskey + '(-)'
		END
	
		SELECT @groupname = NULL
		SELECT @groupname = name
		FROM sys.data_spaces
		WHERE data_space_id = @groupid 
	
		DECLARE IncludeColsCursor CURSOR FOR 
			SELECT obj.name
			FROM sys.index_columns AS col
			INNER JOIN sys.syscolumns AS obj ON col.OBJECT_ID = obj.id AND col.column_id = obj.colid
			WHERE is_included_column = 1
			AND col.OBJECT_ID = @objid
			AND col.index_id = @indid
			ORDER BY col.index_column_id
	
		OPEN IncludeColsCursor
		FETCH IncludeColsCursor INTO @thiskey
		SET @include_cols = ''
	
		WHILE @@FETCH_STATUS = 0
		BEGIN
			SET @include_cols = @include_cols 
				+ CASE WHEN @include_cols = '' THEN ''
					ELSE ', '
				END + @thiskey
			FETCH IncludeColsCursor INTO @thiskey
		END

		CLOSE IncludeColsCursor
		DEALLOCATE IncludeColsCursor

		-- Insert the index data into temp table
		INSERT INTO #table_indexes
		( index_name, index_id, ignore_dup_key,	is_unique, filter_definition, is_hypothetical, is_primary_key, is_unique_key,
		auto_created, no_recompute, data_compression_desc, groupname, index_keys, includes, last_user_seek, last_user_scan,
		last_user_lookup, last_user_update, user_seeks, user_scans, user_lookups, user_updates, orig_fillfactor, index_size_mb )
		VALUES
		( @indname, @indid, @ignore_dup_key, @is_unique, @filter_definition, @is_hypothetical, @is_primary_key, @is_unique_key,
		@auto_created, @no_recompute, @data_compression_desc, @groupname, @keys, @include_cols, @last_user_seek, @last_user_scan,
		@last_user_lookup, @last_user_update, @user_seeks, @user_scans, @user_lookups, @user_updates, @orig_fillfactor, @index_size_mb )
		-- Next index
		FETCH ind_cur INTO @indid, @groupid, @indname, @ignore_dup_key,
		@is_unique, @filter_definition, @is_hypothetical, @is_primary_key, @is_unique_key,
		@auto_created, @no_recompute, @data_compression_desc, @last_user_seek, @last_user_scan,
		@last_user_lookup, @last_user_update, @user_seeks, @user_scans,
		@user_lookups, @user_updates, @orig_fillfactor, @index_size_mb ;
	END
	CLOSE ind_cur
	DEALLOCATE ind_cur
	
	
	-- Move data from one temp table to another.
	INSERT INTO #Results
		(table_name, index_name, index_id, orig_fillfactor, index_description, index_keys, include_cols, 
		 filter_definition, compression_desc, index_size_mb, last_user_seek, last_user_scan, last_user_lookup, last_user_update, 
		 user_seeks, user_scans, user_lookups, user_updates, create_text, rebuild_text, reorganize_text, 
		 drop_text, compress_text, est_compression_savings_text)
	SELECT @objname AS table_name,
		index_name,
		index_id,
		orig_fillfactor,
		CONVERT(VARCHAR(210), 
			CASE WHEN index_id = 1 THEN 'clustered' ELSE 'nonclustered' END 
			+ CASE WHEN ignore_dup_key <> 0 THEN ', ignore duplicate keys' ELSE '' END 
			+ CASE WHEN is_unique <> 0 THEN ', unique' ELSE '' END 
			+ CASE WHEN is_hypothetical <> 0 THEN ', hypothetical' ELSE ''END
			+ CASE WHEN is_primary_key <> 0 THEN ', primary key' ELSE '' END 
			+ CASE WHEN is_unique_key <> 0 THEN ', unique key' ELSE '' END 
			+ CASE WHEN auto_created <> 0 THEN ', auto create' ELSE '' END
			+ CASE WHEN no_recompute <> 0 THEN ', stats no recompute' ELSE '' END 
			+ ' located on ' + COALESCE(groupname,'[default]')
		) AS index_description,
		index_keys,
		includes AS include_cols,
		filter_definition,
		data_compression_desc AS compression_desc,
		index_size_mb,
		last_user_seek,
		last_user_scan,
		last_user_lookup,
		last_user_update,
		user_seeks,
		user_scans,
		user_lookups,
		user_updates,
		'CREATE ' 
			+ CASE WHEN is_unique <> 0 THEN 'UNIQUE ' ELSE '' END  
			+ CASE WHEN index_id = 1 THEN 'CLUSTERED '	ELSE 'NONCLUSTERED ' END 
			+ ' INDEX ' + QUOTENAME(index_name) + ' ON ' + @objname + '(' + index_keys + ')' 
			+ CASE WHEN COALESCE(includes,'') = '' THEN '' ELSE ' INCLUDE (' + includes + ')' END 
			+ CASE WHEN COALESCE(filter_definition,'') = '' THEN '' ELSE ' WHERE ' + filter_definition END 
			+ ' WITH (' + CASE WHEN orig_fillfactor = 0 THEN '' ELSE 'fillfactor = ' + CAST(orig_fillfactor as nvarchar) + ', ' END 
			+ 'DROP_EXISTING = OFF, ONLINE = ON, DATA_COMPRESSION = ' + data_compression_desc + ')'
			+ ' ON ' + QUOTENAME(COALESCE(groupname,'default'))
		AS create_text, 
		'ALTER INDEX [' + index_name + '] ON ' + @objname + ' REBUILD WITH (ONLINE = ON);' AS rebuild_text,
		'ALTER INDEX [' + index_name + '] ON ' + @objname + ' REORGANIZE;' AS reorganize_text,
		'DROP INDEX  [' + index_name + '] ON [' + parsename(@objname,1) + '];' AS drop_text,
		'ALTER INDEX [' + index_name + '] ON ' + @objname + ' REBUILD WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);' AS compress_text,
		'EXEC sp_estimate_data_compression_savings ''' + OBJECT_SCHEMA_NAME(@objid,DB_ID(@dbname)) +  ''', ''' + object_name(@objid,DB_ID(@dbname)) + ''', ' 
			+ COALESCE(CAST(index_id as varchar), 'NULL') + ', NULL, ''PAGE''' 
		AS Est_Compression_Savings_text
	FROM #table_indexes
	ORDER BY index_id DESC
	
	FETCH NEXT FROM tbl_cur INTO @objname
END

CLOSE tbl_cur
DEALLOCATE tbl_cur

--OK, now output everything
-- Just do SELECT * from the temp table, too lazy to list all the columns
SELECT *
FROM #Results
ORDER BY table_name, index_id desc

RETURN (0)
-- sp_helpindex3
GO

