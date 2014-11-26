USE DBA
GO

IF OBJECT_ID (N'dbo.adm_EmailCss', N'FN') IS NOT NULL
    DROP FUNCTION dbo.adm_EmailCss;
GO
CREATE FUNCTION dbo.adm_EmailCss()
RETURNS nvarchar(max)
AS
/*************************************************************************************************
AUTHOR: Andy Mallon
CREATED: 20141001
    This function returns a <style> tag for use in generating formatted HTML emails.

PARAMETERS
* None
**************************************************************************************************
MODIFICATIONS:
    YYYYMMDDD - Initials - Description of changes
**************************************************************************************************
    This code is free to download and use for personal, educational, and internal 
    corporate purposes, provided that this header is preserved. Redistribution or sale, 
    in whole or in part, is prohibited without the author's express written consent.
    
    Copyright 2014 Andy Mallon, www.impatientdba.com
*************************************************************************************************/
BEGIN
    DECLARE @Style nvarchar(max),
            --Use variables for font-family & colors
            --Makes it easier to update them later
            @FontFamily nvarchar(200) = '''Segoe UI'',''Arial'',''Helvetica''',
            @ColorBoldText nvarchar(7) = '#032E57',
            @ColorBackground nvarchar(7) = '#D0CAC4',
            @ColorBackgroundAlt nvarchar(7) = '#F2F5A9';
    
    
    SET @Style = N'<style>
      body {font-family:' + @FontFamily + '; 
            font-size:''12px''}
      h2   {color:' + @ColorBoldText + ';
            font-family:' + @FontFamily + '}
      table,th,td {border:1;
                   cellpadding:1;
                   cellspacing:0;
                   font-family:' + @FontFamily + ';
                   font-size:''12px''}
      tr:nth-child(even) {background-color:' + @ColorBackgroundAlt + '}
      th   {background-color:' + @ColorBackground + ';
            font-size:''13px''}
</style>';
    RETURN(@Style);
END;
GO

