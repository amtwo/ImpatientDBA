IF object_id('dbo.fn_split','IF') IS NULL
	EXEC ('CREATE FUNCTION dbo.fn_split()	RETURNS TABLE	AS	RETURN SELECT 1 AS x')
	GO

ALTER FUNCTION dbo.fn_split (@Text varchar(8000), @Token varchar(20) = ',')
RETURNS TABLE
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 2014-04-20
	Convert a delimited string (any delimiter can be passed, default assumes CSV.

	Use method of converting the CSV value into an XML document to make shredding more efficient.

PARAMETERS:
	@Text - Text string of delimited text
	@Token - Default , - Delimited used to parse the @Text string

EXAMPLES:
* SELECT * FROM dbo.fn_split('A,B,C',default)
* SELECT * FROM dbo.fn_split('A|^B|^C','|^')
**************************************************************************************************
MODIFICATIONS:
**************************************************************************************************
	This code is free to download and use for personal, educational, and internal 
	corporate purposes, provided that this header is preserved. Redistribution or sale, 
	in whole or in part, is prohibited without the author's express written consent.
*************************************************************************************************/
AS
RETURN
SELECT ID = ROW_NUMBER() OVER (ORDER BY Value)
	, Value
FROM (
	SELECT Value = LTRIM(RTRIM(m.n.value('.[1]','varchar(8000)')))
	FROM (
		SELECT CAST('<XMLRoot><RowData>' + REPLACE(@Text,@Token,'</RowData><RowData>') + '</RowData></XMLRoot>' AS XML) AS x
		)t
	CROSS APPLY x.nodes('/XMLRoot/RowData')m(n)
	) AS R
GO
