CREATE FUNCTION dbo.adm_hadr_db_role
(
	@Name sysname
)
RETURNS nvarchar(60)
AS
BEGIN
	DECLARE @Role nvarchar(60);
	DECLARE @Sql nvarchar(max);

	--AM2 Make this work for 2008 & older, too
	--wrap in an IF statement about version
	IF CAST(LEFT(CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(100)),2) as int) >= 11
		WITH hadr_role 
		AS (
			SELECT d.name  COLLATE SQL_Latin1_General_CP1_CI_AS AS Name, 
				d.state_desc  COLLATE SQL_Latin1_General_CP1_CI_AS AS StateDesc, 
				rs.role_desc  COLLATE SQL_Latin1_General_CP1_CI_AS AS RoleDesc
			FROM sys.databases d
			LEFT JOIN sys.dm_hadr_availability_replica_states rs
				ON rs.replica_id = d.replica_id AND rs.is_local = 1
			UNION ALL
			SELECT ag.name COLLATE SQL_Latin1_General_CP1_CI_AS, 
				rs.operational_state_desc COLLATE SQL_Latin1_General_CP1_CI_AS, 
				rs.role_desc  COLLATE SQL_Latin1_General_CP1_CI_AS
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
