CREATE FUNCTION dbo.adm_hadr_db_role
(
	@Name sysname
)
RETURNS nvarchar(60)
AS
BEGIN
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20150706
    If an Availability Group name is passed into @Name, returns PRIMARY or SECONDARY, depending
    on the current role of that AG on this server.
    If a database name is passed as @Name and that DB is part of an AG, returns 
    PRIMARY or SECONDARY, depending on the current role of that AG on this server.
    If a database name is passed as @Name and that DB is NOT part of an AG, returns the 
    database_state_desc from sys.databases
PARAMETERS
* @Name - sysname - The name of a Database or Availability Group
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDDD - Initials - Description of changes
**************************************************************************************************
    This code is free to download and use for personal, educational, and internal 
    corporate purposes, provided that this header is preserved. Redistribution or sale, 
    in whole or in part, is prohibited without the author's express written consent.
    
    Copyright 2015 Andy Mallon, www.impatientdba.com
*************************************************************************************************/
	DECLARE @Role nvarchar(60);
	DECLARE @Sql nvarchar(max);

	--AM2 Make this work for 2008 & older, too
	--wrap in an IF statement about version
	IF CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(100)),2) as int) >= 11
		WITH hadr_role 
		AS (
			SELECT d.name  COLLATE database_default AS Name, 
				d.state_desc  COLLATE database_default AS StateDesc, 
				rs.role_desc  COLLATE database_default AS RoleDesc
			FROM sys.databases d
			LEFT JOIN sys.dm_hadr_availability_replica_states rs
				ON rs.replica_id = d.replica_id AND rs.is_local = 1
			UNION ALL
			SELECT ag.name COLLATE database_default, 
				rs.operational_state_desc COLLATE database_default, 
				rs.role_desc  COLLATE database_default
			FROM sys.availability_groups ag
			LEFT JOIN sys.dm_hadr_availability_replica_states rs
				ON rs.group_id = ag.group_id AND rs.is_local = 1
		)
		SELECT @Role = COALESCE(RoleDesc, StateDesc)
		FROM hadr_role
		WHERE Name = @Name;
	
	ELSE
		SELECT @Role = d.state_desc FROM sys.databases d WHERE d.name = @Name;

	RETURN @Role;
END;
GO
