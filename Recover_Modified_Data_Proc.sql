CREATE OR ALTER PROCEDURE Recover_Modified_Data_Proc
	@Database_Name NVARCHAR(MAX), 
	@SchemaName_n_TableName NVARCHAR(MAX), 
	@Date_From DATETIME='1900/01/01', 
	@Date_To DATETIME='9999/12/31',
	@Start_LSN NVARCHAR(25) = NULL,
	@End_LSN NVARCHAR(25) = NULL
AS
BEGIN
	SET NOCOUNT ON;

    DECLARE @parms NVARCHAR(1024);
    DECLARE @Fileid INT;
    DECLARE @Pageid INT;
    DECLARE @Slotid INT;
    DECLARE @RowLogContents0 VARBINARY(8000);
    DECLARE @RowLogContents1 VARBINARY(8000);
    DECLARE @RowLogContents3 VARBINARY(8000);
    DECLARE @RowLogContents3_Var VARCHAR(MAX);
    DECLARE @RowLogContents4 VARBINARY(8000);
    DECLARE @LogRecord VARBINARY(8000);
    DECLARE @LogRecord_Var VARCHAR(MAX);
    DECLARE @ConsolidatedPageID VARCHAR(MAX);
    DECLARE @AllocUnitID AS BIGINT;
    DECLARE @TransactionID AS VARCHAR(MAX);
    DECLARE @Operation AS VARCHAR(MAX);
    DECLARE @DatabaseCollation VARCHAR(MAX);

    /*  Pick The actual data
    */
    DECLARE @temppagedata TABLE ([ParentObject] sysname, [Object] sysname, [Field] sysname, [Value] sysname);

    DECLARE @pagedata TABLE
    (
        [Page ID] sysname
        , [AllocUnitId] BIGINT
        , [ParentObject] sysname
        , [Object] sysname
        , [Field] sysname
        , [Value] sysname
    );

	DECLARE @time DATETIME, @i INT, @msg NVARCHAR(4000)
	SET @time = GETDATE();

	--Create table collect info from fn_dblog
	DROP TABLE IF EXISTS #fn_dblog
	SELECT  *
	INTO    #fn_dblog
	FROM    sys.fn_dblog(@Start_LSN,@End_LSN)
	WHERE   AllocUnitId IN
				(
					SELECT  [allocation_unit_id]
					FROM    sys.allocation_units allocunits
							INNER JOIN sys.partitions partitions ON (allocunits.type IN ( 1, 3 ) AND   partitions.hobt_id=allocunits.container_id)
																	OR (allocunits.type=2 AND  partitions.partition_id=allocunits.container_id)
					WHERE   object_id=OBJECT_ID(''+@SchemaName_n_TableName+'')
				)
			AND Operation IN ( 'LOP_MODIFY_ROW', 'LOP_MODIFY_COLUMNS' )
			AND [Context] IN ( 'LCX_HEAP', 'LCX_CLUSTERED' )
			AND [Transaction ID] IN 
				(	SELECT  DISTINCT [Transaction ID]	
					FROM    sys.fn_dblog(NULL, NULL)
					WHERE   Context IN ( 'LCX_NULL' )
							AND Operation IN ( 'LOP_BEGIN_XACT' )
							AND [Transaction Name]='UPDATE'
							AND CONVERT(DATETIME, [Begin Time]) BETWEEN @Date_From AND @Date_To 
				);
	
    DECLARE Page_Data_Cursor CURSOR FOR
    /*We need to filter LOP_MODIFY_ROW,LOP_MODIFY_COLUMNS from log for modified records & Get its Slot No, Page ID & AllocUnit ID*/
    SELECT  [Page ID], [Slot ID], [AllocUnitId]
    FROM    #fn_dblog
    --WHERE   AllocUnitId IN
    --        (
    --            SELECT  [allocation_unit_id]
    --            FROM    sys.allocation_units allocunits
    --                    INNER JOIN sys.partitions partitions ON (allocunits.type IN ( 1, 3 ) AND   partitions.hobt_id=allocunits.container_id)
    --                                                            OR (allocunits.type=2 AND  partitions.partition_id=allocunits.container_id)
    --            WHERE   object_id=OBJECT_ID(''+@SchemaName_n_TableName+'')
    --        )
    --        AND Operation IN ( 'LOP_MODIFY_ROW', 'LOP_MODIFY_COLUMNS' )
    --        AND [Context] IN ( 'LCX_HEAP', 'LCX_CLUSTERED' )
    --        /*Use this subquery to filter the date*/
    --        AND [Transaction ID] IN
    --            (
    --                SELECT  DISTINCT
    --                        [Transaction ID]
    --                FROM    sys.fn_dblog(NULL, NULL)
    --                WHERE   Context IN ( 'LCX_NULL' )
    --                        AND Operation IN ( 'LOP_BEGIN_XACT' )
    --                        AND [Transaction Name]='UPDATE'
    --                        AND CONVERT(DATETIME, [Begin Time])
    --                        BETWEEN @Date_From AND @Date_To
    --            )

    /****************************************/
    GROUP BY [Page ID], [Slot ID], [AllocUnitId]
    ORDER BY [Slot ID];

    OPEN Page_Data_Cursor;

    FETCH NEXT FROM Page_Data_Cursor
    INTO @ConsolidatedPageID, @Slotid, @AllocUnitID;

    WHILE @@FETCH_STATUS=0
    BEGIN
        DECLARE @hex_pageid AS VARCHAR(MAX);

        /*Page ID contains File Number and page number It looks like 0001:00000130.
        In this example 0001 is file Number &  00000130 is Page Number & These numbers are in Hex format*/
        SET @Fileid=SUBSTRING(@ConsolidatedPageID, 0, CHARINDEX(':', @ConsolidatedPageID)); -- Seperate File ID from Page ID
        SET @hex_pageid='0x'+SUBSTRING(@ConsolidatedPageID, CHARINDEX(':', @ConsolidatedPageID)+1, LEN(@ConsolidatedPageID)); ---Seperate the page ID

        SELECT  @Pageid=CONVERT(INT
                                , CAST('' AS XML).value('xs:hexBinary(substring(sql:variable("@hex_pageid"),sql:column("t.pos")) )', 'varbinary(max)')
                               )    -- Convert Page ID from hex to integer
        FROM    (SELECT CASE SUBSTRING(@hex_pageid, 1, 2)WHEN '0x' THEN 3 ELSE 0 END) AS t(pos);

        DELETE @temppagedata;

        -- Now we need to get the actual data (After modification) from the page
        INSERT INTO @temppagedata
        EXEC ('DBCC PAGE('+@Database_Name+', '+@Fileid+', '+@Pageid+', 3) with tableresults,no_infomsgs;');

        -- Add Page Number and allocUnit ID in data to identity which one page it belongs to.
        INSERT INTO @pagedata
        SELECT  @ConsolidatedPageID, @AllocUnitID, [ParentObject], [Object], [Field], [Value]
        FROM    @temppagedata;

        FETCH NEXT FROM Page_Data_Cursor
        INTO @ConsolidatedPageID, @Slotid, @AllocUnitID;
    END;

    CLOSE Page_Data_Cursor;
    DEALLOCATE Page_Data_Cursor;

    DECLARE @Newhexstring VARCHAR(MAX);

    DECLARE @ModifiedRawData TABLE
    (
        [ID] INT IDENTITY(1, 1)
        , [PAGE ID] VARCHAR(MAX)
        , [Slot ID] INT
        , [AllocUnitId] BIGINT
        , [RowLog Contents 0_var] VARCHAR(MAX)
        , [RowLog Contents 0] VARBINARY(8000)
    );

    --The modified data is in multiple rows in the page, so we need to convert it into one row as a single hex value.
    --This hex value is in string format
    INSERT INTO @ModifiedRawData ([PAGE ID], [Slot ID], [AllocUnitId], [RowLog Contents 0_var])
    SELECT  B.[Page ID]
            , A.[Slot ID]
            , A.[AllocUnitId]
            , (
                  SELECT    REPLACE(STUFF((
                                              SELECT    REPLACE(SUBSTRING([Value], CHARINDEX(':', [Value])+1, 48), '†', '')
                                              FROM  @pagedata C
                                              WHERE B.[Page ID]=C.[Page ID]
                                                    AND A.[Slot ID]=LTRIM(RTRIM(SUBSTRING(C.[ParentObject], 5, 3)))
                                                    AND [Object] LIKE '%Memory Dump%'
                                              GROUP BY [Value]
                                              FOR XML PATH('')
                                          )
                                          , 1
                                          , 1
                                          , ''
                                         )
                                    , ' '
                                    , ''
                                   )
              ) AS [Value]
    FROM    #fn_dblog A
            INNER JOIN @pagedata B ON A.[Page ID]=B.[Page ID]
                                      AND  A.[AllocUnitId]=B.[AllocUnitId]
                                      AND  A.[Slot ID]=LTRIM(RTRIM(SUBSTRING(B.[ParentObject], 5, 3)))
                                      AND  B.[Object] LIKE '%Memory Dump%'
    
    /****************************************/
    GROUP BY B.[Page ID], A.[Slot ID], A.[AllocUnitId]  --,[Transaction ID]
    ORDER BY [Slot ID];

    -- Convert the hex value data in string, convert it into Hex value as well.
    UPDATE  @ModifiedRawData
    SET [RowLog Contents 0]=CAST('' AS XML).value('xs:hexBinary(substring(sql:column("[RowLog Contents 0_var]"), 0) )', 'varbinary(max)')
    FROM    @ModifiedRawData;

    ---Now we have modifed data plus its slot ID , page ID and allocunit as well.
    --After that we need to get the old values before modfication, these datas are in chunks.
    DECLARE Page_Data_Cursor CURSOR FOR
    SELECT  [Page ID]
            , [Slot ID]
            , [AllocUnitId]
            , [Transaction ID]
            , [RowLog Contents 0]
            , [RowLog Contents 1]
            , [RowLog Contents 3]
            , [RowLog Contents 4]
            , SUBSTRING([Log Record], [Log Record Fixed Length], ([Log Record Length]+1) - ([Log Record Fixed Length])) AS [Log Record]
            , Operation
    FROM    #fn_dblog
	--sys.fn_dblog(NULL, NULL)
	--WHERE AllocUnitId IN
	--			(
	--				SELECT  [allocation_unit_id]
	--				FROM    sys.allocation_units allocunits
	--						INNER JOIN sys.partitions partitions ON (allocunits.type IN ( 1, 3 ) AND   partitions.hobt_id=allocunits.container_id)
	--																OR (allocunits.type=2 AND  partitions.partition_id=allocunits.container_id)
	--				WHERE   object_id=OBJECT_ID(''+@SchemaName_n_TableName+'')
	--			)
	--		AND Operation IN ( 'LOP_MODIFY_ROW', 'LOP_MODIFY_COLUMNS' )
	--		AND [Context] IN ( 'LCX_HEAP', 'LCX_CLUSTERED' )
	--		AND [Transaction ID] IN 
	--			(	SELECT  DISTINCT [Transaction ID]	
	--				FROM    sys.fn_dblog(NULL, NULL)
	--				WHERE   Context IN ( 'LCX_NULL' )
	--						AND Operation IN ( 'LOP_BEGIN_XACT' )
	--						AND [Transaction Name]='UPDATE'
	--						AND CONVERT(DATETIME, [Begin Time]) BETWEEN @Date_From AND @Date_To 
	--			)

    /****************************************/
    ORDER BY [Slot ID], [Transaction ID] DESC;

    OPEN Page_Data_Cursor;

    FETCH NEXT FROM Page_Data_Cursor
    INTO @ConsolidatedPageID
         , @Slotid
         , @AllocUnitID
         , @TransactionID
         , @RowLogContents0
         , @RowLogContents1
         , @RowLogContents3
         , @RowLogContents4
         , @LogRecord
         , @Operation;

    WHILE @@FETCH_STATUS=0
    BEGIN
        IF @Operation='LOP_MODIFY_ROW'
        BEGIN
            /* If it is @Operation Type is 'LOP_MODIFY_ROW' then it is very simple to recover the modified data. The old data is in [RowLog Contents 0] Field and modified data is in [RowLog Contents 1] Field. Simply replace it with the modified data and get the old data.
            */
            INSERT INTO @ModifiedRawData ([PAGE ID], [Slot ID], [AllocUnitId], [RowLog Contents 0_var])
            SELECT  TOP 1
                    @ConsolidatedPageID AS [PAGE ID]
                    , @Slotid AS [Slot ID]
                    , @AllocUnitID AS [AllocUnitId]
                    , REPLACE(UPPER([RowLog Contents 0_var])
                              , UPPER(CAST('' AS XML).value('xs:hexBinary(sql:variable("@RowLogContents1") )', 'varchar(max)'))
                              , UPPER(CAST('' AS XML).value('xs:hexBinary(sql:variable("@RowLogContents0") )', 'varchar(max)'))
                             ) AS [RowLog Contents 0_var]
            FROM    @ModifiedRawData
            WHERE   [PAGE ID]=@ConsolidatedPageID
                    AND [Slot ID]=@Slotid
                    AND [AllocUnitId]=@AllocUnitID
            ORDER BY [ID] DESC;

            --- Convert the old data which is in string format to hex format.
            UPDATE  @ModifiedRawData
            SET [RowLog Contents 0]=CAST('' AS XML).value('xs:hexBinary(substring(sql:column("[RowLog Contents 0_var]"), 0) )', 'varbinary(max)')
            FROM    @ModifiedRawData
            WHERE   [Slot ID]=@Slotid;
        END;

        IF @Operation='LOP_MODIFY_COLUMNS'
        BEGIN

            /* If it is @Operation Type is 'LOP_MODIFY_ROW' then we need to follow a different procedure to recover modified
            .Because this time the data is also in chunks but merge with the data log.
            */
            --First, we need to get the [RowLog Contents 3] Because in [Log Record] field the modified data is available after the [RowLog Contents 3] data.
            SET @RowLogContents3_Var=CAST('' AS XML).value('xs:hexBinary(sql:variable("@RowLogContents3") )', 'varchar(max)');
            SET @LogRecord_Var=CAST('' AS XML).value('xs:hexBinary(sql:variable("@LogRecord"))', 'varchar(max)');

            DECLARE @RowLogData_Var VARCHAR(MAX);
            DECLARE @RowLogData_Hex VARBINARY(MAX);

            ---First get the modifed data chunks in string format
            SET @RowLogData_Var=SUBSTRING(@LogRecord_Var
                                          , CHARINDEX(@RowLogContents3_Var, @LogRecord_Var)+LEN(@RowLogContents3_Var)
                                          , LEN(@LogRecord_Var)
                                         );

            --Then convert it into the hex values.
            SELECT  @RowLogData_Hex=CAST('' AS XML).value('xs:hexBinary( substring(sql:variable("@RowLogData_Var"),0) )', 'varbinary(max)')
            FROM    (SELECT CASE SUBSTRING(@RowLogData_Var, 1, 2)WHEN '0x' THEN 3 ELSE 0 END) AS t(pos);

            DECLARE @TotalFixedLengthData INT;
            DECLARE @FixedLength_Offset INT;
            DECLARE @VariableLength_Offset INT;
            DECLARE @VariableLength_Offset_Start INT;
            DECLARE @VariableLengthIncrease INT;
            DECLARE @FixedLengthIncrease INT;
            DECLARE @OldFixedLengthStartPosition INT;
            DECLARE @FixedLength_Loc INT;
            DECLARE @VariableLength_Loc INT;
            DECLARE @FixedOldValues VARBINARY(MAX);
            DECLARE @FixedNewValues VARBINARY(MAX);
            DECLARE @VariableOldValues VARBINARY(MAX);
            DECLARE @VariableNewValues VARBINARY(MAX);

            -- Before recovering the modfied data we need to get the total fixed length data size and start position of the varaible data
            SELECT  TOP 1
                    @TotalFixedLengthData=CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2+1, 2))))
                    , @VariableLength_Offset_Start
                          =CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2+1, 2))))+5
                           +CONVERT(
                                   INT
                                   , CEILING(
                                            CONVERT(
                                                   INT
                                                   , CONVERT(
                                                            BINARY(2)
                                                            , REVERSE(
                                                                     SUBSTRING(
                                                                              [RowLog Contents 0]
                                                                              , CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2+1, 2))))
                                                                                +1
                                                                              , 2
                                                                              )
                                                                     )
                                                            )
                                                   )/ 8.0
                                            )
                                   )
            FROM    @ModifiedRawData
            ORDER BY [ID] DESC;

            SET @FixedLength_Offset=CONVERT(BINARY(2), REVERSE(CONVERT(BINARY(4), (@RowLogContents0)))); --)
            SET @VariableLength_Offset=CONVERT(INT, CONVERT(BINARY(2), REVERSE(@RowLogContents0)));

            /* We already have modified data chunks in @RowLogData_Hex but this data is in merge format (modified plus actual data)
            So , here we need [Row Log Contents 1] field , because in this field we have the data length both the modified and actual data
            so this length will help us to break it into original and modified data chunks.
            */
            SET @FixedLength_Loc=CONVERT(INT, SUBSTRING(@RowLogContents1, 1, 1));
            SET @VariableLength_Loc=CONVERT(INT, SUBSTRING(@RowLogContents1, 3, 1));

            /*First , we need to break Fix length data actual with the help of data length  */
            SET @OldFixedLengthStartPosition=CHARINDEX(@RowLogContents4, @RowLogData_Hex);
            SET @FixedOldValues=SUBSTRING(@RowLogData_Hex, @OldFixedLengthStartPosition, @FixedLength_Loc);
            SET @FixedLengthIncrease= (CASE WHEN (LEN(@FixedOldValues)% 4) =0 THEN 1 ELSE (4- (LEN(@FixedOldValues)% 4)) END);
            /*After that , we need to break Fix length data modified data with the help of data length  */
            SET @FixedNewValues=SUBSTRING(@RowLogData_Hex
                                          , @OldFixedLengthStartPosition+@FixedLength_Loc+@FixedLengthIncrease
                                          , @FixedLength_Loc
                                         );

            /*Same we need to break the variable data with the help of data length*/
            SET @VariableOldValues=SUBSTRING(@RowLogData_Hex
                                             , @OldFixedLengthStartPosition+@FixedLength_Loc+@FixedLengthIncrease+@FixedLength_Loc+ (@FixedLengthIncrease)
                                             , @VariableLength_Loc
                                            );
            SET @VariableLengthIncrease= (CASE WHEN (LEN(@VariableOldValues)% 4) =0 THEN 1 ELSE (4- (LEN(@VariableOldValues)% 4)) +1 END);
            SET @VariableOldValues= (CASE WHEN @VariableLength_Loc=1 THEN @VariableOldValues+0x00 ELSE @VariableOldValues END);
            SET @VariableNewValues
                =SUBSTRING(
                          SUBSTRING(
                                   @RowLogData_Hex
                                   , @OldFixedLengthStartPosition+@FixedLength_Loc+@FixedLengthIncrease+@FixedLength_Loc+ (@FixedLengthIncrease-1)
                                     +@VariableLength_Loc+@VariableLengthIncrease
                                   , LEN(@RowLogData_Hex)+1
                                   )
                          , 1
                          , LEN(@RowLogData_Hex)+1
                          ); --LEN(@VariableOldValues)

            /*here we need to replace the fixed length &  variable length actaul data with modifed data
            */
			--SELECT @RowLogData_Hex, @OldFixedLengthStartPosition, @FixedLength_Loc, @FixedLengthIncrease, @VariableLength_Loc, @VariableLengthIncrease, @VariableNewValues
            SELECT  TOP 1
                    @VariableNewValues
                        =CASE WHEN CHARINDEX(SUBSTRING(@VariableNewValues, 0, LEN(@VariableNewValues)+1), [RowLog Contents 0])<>0
                              THEN SUBSTRING(@VariableNewValues, 0, LEN(@VariableNewValues)+1)
                             WHEN CHARINDEX(SUBSTRING(@VariableNewValues, 0, LEN(@VariableNewValues)), [RowLog Contents 0])<>0
                             THEN SUBSTRING(@VariableNewValues, 0, LEN(@VariableNewValues))
                             WHEN CHARINDEX(SUBSTRING(@VariableNewValues, 0, LEN(@VariableNewValues)-1), [RowLog Contents 0])<>0
                             THEN SUBSTRING(@VariableNewValues, 0, LEN(@VariableNewValues)-1) --3 --Substring(@VariableNewValues,0,Len(@VariableNewValues)-1)
                             WHEN CHARINDEX(SUBSTRING(@VariableNewValues, 0, LEN(@VariableNewValues)-2), [RowLog Contents 0])<>0
                             THEN SUBSTRING(@VariableNewValues, 0, LEN(@VariableNewValues)-2)
                             WHEN CHARINDEX(SUBSTRING(@VariableNewValues, 0, LEN(@VariableNewValues)-3), [RowLog Contents 0])<>0
                             THEN SUBSTRING(@VariableNewValues, 0, LEN(@VariableNewValues)-3) --5--Substring(@VariableNewValues,0,Len(@VariableNewValues)-3)
                         END
            FROM    @ModifiedRawData
            WHERE   [Slot ID]=@Slotid
            ORDER BY [ID] DESC;

            INSERT INTO @ModifiedRawData ([PAGE ID], [Slot ID], [AllocUnitId], [RowLog Contents 0_var], [RowLog Contents 0])
            SELECT  TOP 1
                    @ConsolidatedPageID AS [PAGE ID]
                    , @Slotid AS [Slot ID]
                    , @AllocUnitID AS [AllocUnitId]
                    , NULL
                    , CAST(REPLACE(SUBSTRING([RowLog Contents 0], 0, @TotalFixedLengthData+1), @FixedNewValues, @FixedOldValues) AS VARBINARY(MAX))
                      +SUBSTRING([RowLog Contents 0], @TotalFixedLengthData+1, 2)
                      +SUBSTRING([RowLog Contents 0]
                                 , @TotalFixedLengthData+3
                                 , CONVERT(INT
                                           , CEILING(CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], @TotalFixedLengthData+1, 2))))/ 8.0)
                                          )
                                )
                      +SUBSTRING(
                                [RowLog Contents 0]
                                , @TotalFixedLengthData+3
                                  +CONVERT(INT
                                           , CEILING(CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], @TotalFixedLengthData+1, 2))))/ 8.0)
                                          )
                                , 2
                                )+SUBSTRING([RowLog Contents 0]
                                            , @VariableLength_Offset_Start
                                            , (@VariableLength_Offset- (@VariableLength_Offset_Start-1))
                                           )+CAST(REPLACE(SUBSTRING([RowLog Contents 0], @VariableLength_Offset+1, LEN(@VariableNewValues))
                                                          , @VariableNewValues
                                                          , @VariableOldValues
                                                         ) AS VARBINARY)
                      +SUBSTRING([RowLog Contents 0], @VariableLength_Offset+LEN(@VariableNewValues)+1, LEN([RowLog Contents 0]))
            FROM    @ModifiedRawData
            WHERE   [Slot ID]=@Slotid
            ORDER BY [ID] DESC;
        END;

        FETCH NEXT FROM Page_Data_Cursor
        INTO @ConsolidatedPageID
             , @Slotid
             , @AllocUnitID
             , @TransactionID
             , @RowLogContents0
             , @RowLogContents1
             , @RowLogContents3
             , @RowLogContents4
             , @LogRecord
             , @Operation;
    END;

    CLOSE Page_Data_Cursor;
    DEALLOCATE Page_Data_Cursor;

	DROP TABLE IF EXISTS #fn_dblog;

    DECLARE @RowLogContents VARBINARY(8000);
    DECLARE @AllocUnitName NVARCHAR(MAX);
    DECLARE @SQL NVARCHAR(MAX);

    DECLARE @bitTable TABLE ([ID] INT, [Bitvalue] INT);

    ----Create table to set the bit position of one byte.
    INSERT INTO @bitTable
    SELECT  0, 2
    UNION ALL
    SELECT  1, 2
    UNION ALL
    SELECT  2, 4
    UNION ALL
    SELECT  3, 8
    UNION ALL
    SELECT  4, 16
    UNION ALL
    SELECT  5, 32
    UNION ALL
    SELECT  6, 64
    UNION ALL
    SELECT  7, 128;

    --Create table to collect the row data.
    DECLARE @DeletedRecords TABLE
    (
        [ID] INT IDENTITY(1, 1)
        , [RowLogContents] VARBINARY(8000)
        , [AllocUnitID] BIGINT
        , [Transaction ID] NVARCHAR(MAX)
        , [Slot ID] INT
        , [FixedLengthData] SMALLINT
        , [TotalNoOfCols] SMALLINT
        , [NullBitMapLength] SMALLINT
        , [NullBytes] VARBINARY(8000)
        , [TotalNoofVarCols] SMALLINT
        , [ColumnOffsetArray] VARBINARY(8000)
        , [VarColumnStart] SMALLINT
        , [NullBitMap] VARCHAR(MAX)
    )
    --Create a common table expression to get all the row data plus how many bytes we have for each row.
    ;

    WITH
    RowData AS (SELECT  [RowLog Contents 0] AS [RowLogContents]
                        , @AllocUnitID AS [AllocUnitID]
                        , [ID] AS [Transaction ID]
                        , [Slot ID] AS [Slot ID]
                                                                                                                                        --[Fixed Length Data] = Substring (RowLog content 0, Status Bit A+ Status Bit B + 1,2 bytes)
                        , CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2+1, 2)))) AS [FixedLengthData]   --@FixedLengthData

                                                                                                                                        --[TotalnoOfCols] =  Substring (RowLog content 0, [Fixed Length Data] + 1,2 bytes)
                        , CONVERT(INT
                                  , CONVERT(BINARY(2)
                                            , REVERSE(SUBSTRING([RowLog Contents 0]
                                                                , CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2+1, 2))))+1
                                                                , 2
                                                               )
                                                     )
                                           )
                                 ) AS [TotalNoOfCols]

                                                                                                                                        --[NullBitMapLength]=ceiling([Total No of Columns] /8.0)
                        , CONVERT(
                                 INT
                                 , CEILING(
                                          CONVERT(
                                                 INT
                                                 , CONVERT(
                                                          BINARY(2)
                                                          , REVERSE(
                                                                   SUBSTRING(
                                                                            [RowLog Contents 0]
                                                                            , CONVERT(
                                                                                     SMALLINT, CONVERT(
                                                                                                      BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2+1, 2))
                                                                                                      )
                                                                                     )+1
                                                                            , 2
                                                                            )
                                                                   )
                                                          )
                                                 )/ 8.0
                                          )
                                 ) AS [NullBitMapLength]

                                                                                                                                        --[Null Bytes] = Substring (RowLog content 0, Status Bit A+ Status Bit B + [Fixed Length Data] +1, [NullBitMapLength] )
                        , SUBSTRING(
                                   [RowLog Contents 0]
                                   , CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2+1, 2))))+3
                                   , CONVERT(
                                            INT
                                            , CEILING(
                                                     CONVERT(
                                                            INT
                                                            , CONVERT(
                                                                     BINARY(2)
                                                                     , REVERSE(
                                                                              SUBSTRING(
                                                                                       [RowLog Contents 0]
                                                                                       , CONVERT(
                                                                                                SMALLINT, CONVERT(
                                                                                                                 BINARY(2), REVERSE(
                                                                                                                                   SUBSTRING(
                                                                                                                                            [RowLog Contents 0], 2
                                                                                                                                                                 +1, 2
                                                                                                                                            )
                                                                                                                                   )
                                                                                                                 )
                                                                                                )+1
                                                                                       , 2
                                                                                       )
                                                                              )
                                                                     )
                                                            )/ 8.0
                                                     )
                                            )
                                   ) AS [NullBytes]

                                                                                                                                        --[TotalNoofVarCols] = Substring (RowLog content 0, Status Bit A+ Status Bit B + [Fixed Length Data] +1, [Null Bitmap length] + 2 )
                        , (CASE WHEN SUBSTRING([RowLog Contents 0], 1, 1) IN ( 0x30, 0x70 )
                                THEN CONVERT(
                                            INT
                                            , CONVERT(
                                                     BINARY(2)
                                                     , REVERSE(
                                                              SUBSTRING(
                                                                       [RowLog Contents 0]
                                                                       , CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2+1, 2))))
                                                                         +3
                                                                         +CONVERT(
                                                                                 INT
                                                                                 , CEILING(
                                                                                          CONVERT(
                                                                                                 INT
                                                                                                 , CONVERT(
                                                                                                          BINARY(2)
                                                                                                          , REVERSE(
                                                                                                                   SUBSTRING(
                                                                                                                            [RowLog Contents 0]
                                                                                                                            , CONVERT(
                                                                                                                                     SMALLINT, CONVERT(
                                                                                                                                                      BINARY(2), REVERSE(
                                                                                                                                                                        SUBSTRING(
                                                                                                                                                                                 [RowLog Contents 0], 2
                                                                                                                                                                                                      +1, 2
                                                                                                                                                                                 )
                                                                                                                                                                        )
                                                                                                                                                      )
                                                                                                                                     )+1
                                                                                                                            , 2
                                                                                                                            )
                                                                                                                   )
                                                                                                          )
                                                                                                 )/ 8.0
                                                                                          )
                                                                                 )
                                                                       , 2
                                                                       )
                                                              )
                                                     )
                                            )
                               ELSE NULL
                           END
                          ) AS [TotalNoofVarCols]

                                                                                                                                        --[ColumnOffsetArray]= Substring (RowLog content 0, Status Bit A+ Status Bit B + [Fixed Length Data] +1, [Null Bitmap length] + 2 , [TotalNoofVarCols]*2 )
                        , (CASE WHEN SUBSTRING([RowLog Contents 0], 1, 1) IN ( 0x30, 0x70 )
                                THEN SUBSTRING(
                                              [RowLog Contents 0]
                                              , CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2+1, 2))))+3
                                                +CONVERT(
                                                        INT
                                                        , CEILING(
                                                                 CONVERT(
                                                                        INT
                                                                        , CONVERT(
                                                                                 BINARY(2)
                                                                                 , REVERSE(
                                                                                          SUBSTRING(
                                                                                                   [RowLog Contents 0]
                                                                                                   , CONVERT(
                                                                                                            SMALLINT, CONVERT(
                                                                                                                             BINARY(2), REVERSE(
                                                                                                                                               SUBSTRING(
                                                                                                                                                        [RowLog Contents 0], 2
                                                                                                                                                                             +1, 2
                                                                                                                                                        )
                                                                                                                                               )
                                                                                                                             )
                                                                                                            )+1
                                                                                                   , 2
                                                                                                   )
                                                                                          )
                                                                                 )
                                                                        )/ 8.0
                                                                 )
                                                        )+2
                                              , (CASE WHEN SUBSTRING([RowLog Contents 0], 1, 1) IN ( 0x30, 0x70 )
                                                      THEN CONVERT(
                                                                  INT
                                                                  , CONVERT(
                                                                           BINARY(2)
                                                                           , REVERSE(
                                                                                    SUBSTRING(
                                                                                             [RowLog Contents 0]
                                                                                             , CONVERT(
                                                                                                      SMALLINT, CONVERT(
                                                                                                                       BINARY(2), REVERSE(
                                                                                                                                         SUBSTRING(
                                                                                                                                                  [RowLog Contents 0], 2
                                                                                                                                                                       +1, 2
                                                                                                                                                  )
                                                                                                                                         )
                                                                                                                       )
                                                                                                      )+3
                                                                                               +CONVERT(
                                                                                                       INT
                                                                                                       , CEILING(
                                                                                                                CONVERT(
                                                                                                                       INT
                                                                                                                       , CONVERT(
                                                                                                                                BINARY(2)
                                                                                                                                , REVERSE(
                                                                                                                                         SUBSTRING(
                                                                                                                                                  [RowLog Contents 0]
                                                                                                                                                  , CONVERT(
                                                                                                                                                           SMALLINT, CONVERT(
                                                                                                                                                                            BINARY(2), REVERSE(
                                                                                                                                                                                              SUBSTRING(
                                                                                                                                                                                                       [RowLog Contents 0], 2
                                                                                                                                                                                                                            +1, 2
                                                                                                                                                                                                       )
                                                                                                                                                                                              )
                                                                                                                                                                            )
                                                                                                                                                           )+1
                                                                                                                                                  , 2
                                                                                                                                                  )
                                                                                                                                         )
                                                                                                                                )
                                                                                                                       )/ 8.0
                                                                                                                )
                                                                                                       )
                                                                                             , 2
                                                                                             )
                                                                                    )
                                                                           )
                                                                  )
                                                     ELSE NULL
                                                 END
                                                ) * 2
                                              )
                               ELSE NULL
                           END
                          ) AS [ColumnOffsetArray]

                                                                                                                                        --  Variable column Start = Status Bit A+ Status Bit B + [Fixed Length Data] + [Null Bitmap length] + 2+([TotalNoofVarCols]*2)
                        , CASE WHEN SUBSTRING([RowLog Contents 0], 1, 1) IN ( 0x30, 0x70 )
                               THEN (CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2+1, 2))))+4
                                     +CONVERT(
                                             INT
                                             , CEILING(
                                                      CONVERT(
                                                             INT
                                                             , CONVERT(
                                                                      BINARY(2)
                                                                      , REVERSE(
                                                                               SUBSTRING(
                                                                                        [RowLog Contents 0]
                                                                                        , CONVERT(
                                                                                                 SMALLINT, CONVERT(
                                                                                                                  BINARY(2), REVERSE(
                                                                                                                                    SUBSTRING(
                                                                                                                                             [RowLog Contents 0], 2
                                                                                                                                                                  +1, 2
                                                                                                                                             )
                                                                                                                                    )
                                                                                                                  )
                                                                                                 )+1
                                                                                        , 2
                                                                                        )
                                                                               )
                                                                      )
                                                             )/ 8.0
                                                      )
                                             )
                                     + ((CASE WHEN SUBSTRING([RowLog Contents 0], 1, 1) IN ( 0x30, 0x70 )
                                              THEN CONVERT(
                                                          INT
                                                          , CONVERT(
                                                                   BINARY(2)
                                                                   , REVERSE(
                                                                            SUBSTRING(
                                                                                     [RowLog Contents 0]
                                                                                     , CONVERT(
                                                                                              SMALLINT, CONVERT(
                                                                                                               BINARY(2), REVERSE(
                                                                                                                                 SUBSTRING(
                                                                                                                                          [RowLog Contents 0], 2
                                                                                                                                                               +1, 2
                                                                                                                                          )
                                                                                                                                 )
                                                                                                               )
                                                                                              )+3
                                                                                       +CONVERT(
                                                                                               INT
                                                                                               , CEILING(
                                                                                                        CONVERT(
                                                                                                               INT
                                                                                                               , CONVERT(
                                                                                                                        BINARY(2)
                                                                                                                        , REVERSE(
                                                                                                                                 SUBSTRING(
                                                                                                                                          [RowLog Contents 0]
                                                                                                                                          , CONVERT(
                                                                                                                                                   SMALLINT, CONVERT(
                                                                                                                                                                    BINARY(2), REVERSE(
                                                                                                                                                                                      SUBSTRING(
                                                                                                                                                                                               [RowLog Contents 0], 2
                                                                                                                                                                                                                    +1, 2
                                                                                                                                                                                               )
                                                                                                                                                                                      )
                                                                                                                                                                    )
                                                                                                                                                   )+1
                                                                                                                                          , 2
                                                                                                                                          )
                                                                                                                                 )
                                                                                                                        )
                                                                                                               )/ 8.0
                                                                                                        )
                                                                                               )
                                                                                     , 2
                                                                                     )
                                                                            )
                                                                   )
                                                          )
                                             ELSE NULL
                                         END
                                        ) * 2
                                       )
                                    )
                              ELSE NULL
                          END AS [VarColumnStart]
                FROM    @ModifiedRawData)
    ---Use this technique to repeate the row till the no of bytes of the row.
    ,
    N1 (n) AS (SELECT   1 UNION ALL SELECT  1)
    ,
    N2 (n) AS (SELECT   1 FROM  N1 AS X, N1 AS Y)
    ,
    N3 (n) AS (SELECT   1 FROM  N2 AS X, N2 AS Y)
    ,
    N4 (n) AS (SELECT   ROW_NUMBER() OVER (ORDER BY X.n) FROM   N3 AS X, N3 AS Y)
    INSERT INTO @DeletedRecords
    SELECT  RowLogContents
            , [AllocUnitID]
            , [Transaction ID]
            , [Slot ID]
            , [FixedLengthData]
            , [TotalNoOfCols]
            , [NullBitMapLength]
            , [NullBytes]
            , [TotalNoofVarCols]
            , [ColumnOffsetArray]
            , [VarColumnStart]
            --Get the Null value against each column (1 means null zero means not null)
            , [NullBitMap]= (REPLACE(STUFF((
                                               SELECT   ','+ (CASE WHEN [ID]=0
                                                                   THEN CONVERT(NVARCHAR(1), (SUBSTRING(NullBytes, n, 1)% 2))
                                                                  ELSE CONVERT(NVARCHAR(1), ((SUBSTRING(NullBytes, n, 1)/ [Bitvalue]) % 2))
                                                              END
                                                             )  --as [nullBitMap]
                                               FROM N4 AS Nums
                                                    JOIN RowData AS C ON n<=NullBitMapLength
                                                    CROSS JOIN @bitTable
                                               WHERE C.[RowLogContents]=D.[RowLogContents]
                                               ORDER BY [RowLogContents], n ASC
                                               FOR XML PATH('')
                                           )
                                           , 1
                                           , 1
                                           , ''
                                          )
                                     , ','
                                     , ''
                                    )
                            )
    FROM    RowData D;

    CREATE TABLE [#temp_Data]
    (
        [FieldName] VARCHAR(MAX) COLLATE DATABASE_DEFAULT NOT NULL
        , [FieldValue] VARCHAR(MAX) COLLATE DATABASE_DEFAULT NULL
        , [Rowlogcontents] VARBINARY(8000)
        , [Transaction ID] VARCHAR(MAX) COLLATE DATABASE_DEFAULT NOT NULL
        , [Slot ID] INT
        , [NonID] INT,
    --[System_type_id] int
    )
    ---Create common table expression and join it with the rowdata table
    --to get each column details
    ;

    WITH
    CTE AS (
           /*This part is for variable data columns*/
           SELECT   A.[ID]
                    , RowLogContents
                    , [Transaction ID]
                    , [Slot ID]
                    , name
                    , cols.leaf_null_bit AS nullbit
                    , leaf_offset
                    , ISNULL(syscolumns.length, cols.max_length) AS [length]
                    , cols.system_type_id
                    , cols.leaf_bit_position AS bitpos
                    , ISNULL(syscolumns.xprec, cols.precision) AS xprec
                    , ISNULL(syscolumns.xscale, cols.scale) AS xscale
                    , SUBSTRING([NullBitMap], cols.leaf_null_bit, 1) AS is_null
                    --Calculate the variable column size from the variable column offset array
                    , (CASE WHEN leaf_offset<1
                                 AND SUBSTRING([NullBitMap], cols.leaf_null_bit, 1)=0
                            THEN CONVERT(SMALLINT
                                         , CONVERT(BINARY(2), REVERSE(SUBSTRING([ColumnOffsetArray], (2 * leaf_offset *-1) -1, 2)))
                                        )
                           ELSE 0
                       END
                      ) AS [Column value Size]
                    ---Calculate the column length
                    , (CASE WHEN leaf_offset<1
                                 AND SUBSTRING([NullBitMap], cols.leaf_null_bit, 1)=0
                            THEN CONVERT(SMALLINT
                                         , CONVERT(BINARY(2), REVERSE(SUBSTRING([ColumnOffsetArray], (2 * (leaf_offset *-1)) -1, 2)))
                                        )
                                 -ISNULL(NULLIF(CONVERT(SMALLINT
                                                        , CONVERT(BINARY(2), REVERSE(SUBSTRING([ColumnOffsetArray], (2 * ((leaf_offset *-1) -1)) -1, 2)))
                                                       )
                                                , 0
                                               )
                                         , [VarColumnStart]
                                        )
                           ELSE 0
                       END
                      ) AS [Column Length]

                    --Get the Hexa decimal value from the RowlogContent
                    --HexValue of the variable column=Substring([Column value Size] - [Column Length] + 1,[Column Length])
                    --This is the data of your column but in the Hexvalue
                    , CASE WHEN SUBSTRING([NullBitMap], cols.leaf_null_bit, 1)=1
                           THEN NULL
                          ELSE
                          SUBSTRING(
                                   RowLogContents
                                   , ((CASE WHEN leaf_offset<1
                                                 AND  SUBSTRING([NullBitMap], cols.leaf_null_bit, 1)=0
                                            THEN CONVERT(SMALLINT
                                                         , CONVERT(BINARY(2), REVERSE(SUBSTRING([ColumnOffsetArray], (2 * leaf_offset *-1) -1, 2)))
                                                        )
                                           ELSE 0
                                       END
                                      )
                                      - ((CASE WHEN leaf_offset<1
                                                    AND SUBSTRING([NullBitMap], cols.leaf_null_bit, 1)=0
                                               THEN CONVERT(SMALLINT
                                                            , CONVERT(BINARY(2), REVERSE(SUBSTRING([ColumnOffsetArray], (2 * (leaf_offset *-1)) -1, 2)))
                                                           )
                                                    -ISNULL(
                                                           NULLIF(
                                                                 CONVERT(
                                                                        SMALLINT
                                                                        , CONVERT(
                                                                                 BINARY(2), REVERSE(
                                                                                                   SUBSTRING(
                                                                                                            [ColumnOffsetArray], (2 * ((leaf_offset *-1) -1))
                                                                                                                                 -1, 2
                                                                                                            )
                                                                                                   )
                                                                                 )
                                                                        )
                                                                 , 0
                                                                 )
                                                           , [VarColumnStart]
                                                           )
                                              ELSE 0
                                          END
                                         )
                                        )
                                     ) +1
                                   , ((CASE WHEN leaf_offset<1
                                                 AND  SUBSTRING([NullBitMap], cols.leaf_null_bit, 1)=0
                                            THEN CONVERT(SMALLINT
                                                         , CONVERT(BINARY(2), REVERSE(SUBSTRING([ColumnOffsetArray], (2 * (leaf_offset *-1)) -1, 2)))
                                                        )
                                                 -ISNULL(
                                                        NULLIF(
                                                              CONVERT(
                                                                     SMALLINT
                                                                     , CONVERT(
                                                                              BINARY(2), REVERSE(
                                                                                                SUBSTRING(
                                                                                                         [ColumnOffsetArray], (2 * ((leaf_offset *-1) -1)) -1, 2
                                                                                                         )
                                                                                                )
                                                                              )
                                                                     )
                                                              , 0
                                                              )
                                                        , [VarColumnStart]
                                                        )
                                           ELSE 0
                                       END
                                      )
                                     )
                                   )
                      END AS hex_Value
           FROM @DeletedRecords A
                INNER JOIN sys.allocation_units allocunits ON A.[AllocUnitID]=allocunits.[allocation_unit_id]
                INNER JOIN sys.partitions partitions ON (allocunits.type IN ( 1, 3 ) AND partitions.hobt_id=allocunits.container_id)
                                                        OR  (allocunits.type=2 AND  partitions.partition_id=allocunits.container_id)
                INNER JOIN sys.system_internals_partition_columns cols ON cols.partition_id=partitions.partition_id
                LEFT OUTER JOIN syscolumns ON syscolumns.id=partitions.object_id
                                              AND   syscolumns.colid=cols.partition_column_id
           WHERE leaf_offset<0
           UNION
           /*This part is for fixed data columns*/
           SELECT   A.[ID]
                    , RowLogContents
                    , [Transaction ID]
                    , [Slot ID]
                    , name
                    , cols.leaf_null_bit AS nullbit
                    , leaf_offset
                    , ISNULL(syscolumns.length, cols.max_length) AS [length]
                    , cols.system_type_id
                    , cols.leaf_bit_position AS bitpos
                    , ISNULL(syscolumns.xprec, cols.precision) AS xprec
                    , ISNULL(syscolumns.xscale, cols.scale) AS xscale
                    , SUBSTRING([NullBitMap], cols.leaf_null_bit, 1) AS is_null
                    , (
                          SELECT    TOP 1
                                    ISNULL(SUM(CASE WHEN C.leaf_offset>1 THEN max_length ELSE 0 END), 0)
                          FROM      sys.system_internals_partition_columns C
                          WHERE  cols.partition_id=C.partition_id
                                 AND C.leaf_null_bit<cols.leaf_null_bit
                      ) +5 AS [Column value Size]
                    , syscolumns.length AS [Column Length]
                    , CASE WHEN SUBSTRING([NullBitMap], cols.leaf_null_bit, 1)=1
                           THEN NULL
                          ELSE SUBSTRING(RowLogContents
                                         , (
                                               SELECT   TOP 1
                                                        ISNULL(SUM(CASE WHEN C.leaf_offset>1 THEN max_length ELSE 0 END), 0)
                                               FROM     sys.system_internals_partition_columns C
                                               WHERE cols.partition_id=C.partition_id
                                                     AND C.leaf_null_bit<cols.leaf_null_bit
                                           ) +5
                                         , syscolumns.length
                                        )
                      END AS hex_Value
           FROM @DeletedRecords A
                INNER JOIN sys.allocation_units allocunits ON A.[AllocUnitID]=allocunits.[allocation_unit_id]
                INNER JOIN sys.partitions partitions ON (allocunits.type IN ( 1, 3 ) AND partitions.hobt_id=allocunits.container_id)
                                                        OR  (allocunits.type=2 AND  partitions.partition_id=allocunits.container_id)
                INNER JOIN sys.system_internals_partition_columns cols ON cols.partition_id=partitions.partition_id
                LEFT OUTER JOIN syscolumns ON syscolumns.id=partitions.object_id
                                              AND   syscolumns.colid=cols.partition_column_id
           WHERE leaf_offset>0)

    --Converting data from Hexvalue to its orgional datatype.
    --Implemented datatype conversion mechanism for each datatype
    --Select * from sys.columns Where [object_id]=object_id('' + @SchemaName_n_TableName + '')
    --Select * from CTE

    INSERT INTO #temp_Data
    SELECT  name
            , CASE WHEN system_type_id IN ( 231, 239 )
                   THEN LTRIM(RTRIM(CONVERT(NVARCHAR(MAX), hex_Value)))                                                 --NVARCHAR ,NCHAR
                  WHEN system_type_id IN ( 167, 175 )
                  THEN LTRIM(RTRIM(CONVERT(VARCHAR(MAX), REPLACE(hex_Value, 0x00, 0x20))))                              --VARCHAR,CHAR
                  WHEN system_type_id=48
                  THEN CONVERT(VARCHAR(MAX), CONVERT(TINYINT, CONVERT(BINARY(1), REVERSE(hex_Value))))                  --TINY INTEGER
                  WHEN system_type_id=52
                  THEN CONVERT(VARCHAR(MAX), CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(hex_Value))))                 --SMALL INTEGER
                  WHEN system_type_id=56
                  THEN CONVERT(VARCHAR(MAX), CONVERT(INT, CONVERT(BINARY(4), REVERSE(hex_Value))))                      -- INTEGER
                  WHEN system_type_id=127
                  THEN CONVERT(VARCHAR(MAX), CONVERT(BIGINT, CONVERT(BINARY(8), REVERSE(hex_Value))))                   -- BIG INTEGER
                  WHEN system_type_id=61
                  THEN CONVERT(VARCHAR(MAX), CONVERT(DATETIME, CONVERT(VARBINARY(8000), REVERSE(hex_Value))), 100)      --DATETIME
                  WHEN system_type_id = 40 
				  THEN CONVERT(VARCHAR(MAX), CONVERT(DATE, CONVERT(VARBINARY(8000), (hex_Value))),100)					--DATE
                  WHEN system_type_id=58
                  THEN CONVERT(VARCHAR(MAX), CONVERT(SMALLDATETIME, CONVERT(VARBINARY(8000), REVERSE(hex_Value))), 100) --SMALL DATETIME
                 
				 WHEN system_type_id=108
                  THEN CONVERT(VARCHAR(MAX), CAST(CONVERT(NUMERIC(38, 30), CONVERT(VARBINARY, CONVERT(VARBINARY, xprec)+CONVERT(VARBINARY, xscale))+CONVERT(VARBINARY(1), 0)+hex_Value
														)
												AS FLOAT)
                              )                                                                                         --- NUMERIC
                  WHEN system_type_id IN ( 60, 122 )
                  THEN CONVERT(VARCHAR(MAX), CONVERT(MONEY, CONVERT(VARBINARY(8000), REVERSE(hex_Value))), 2)           --MONEY,SMALLMONEY
                  WHEN system_type_id=106
                  THEN CONVERT(
                              VARCHAR(MAX)
                              , CAST(CONVERT(DECIMAL(38, 34)
                                             , CONVERT(VARBINARY, CONVERT(VARBINARY, xprec)+CONVERT(VARBINARY, xscale))+CONVERT(VARBINARY(1), 0)+hex_Value
                                            ) AS FLOAT)
                              )                                                                                         --- DECIMAL
                  WHEN system_type_id=104
                  THEN CONVERT(VARCHAR(MAX), CONVERT(BIT, CONVERT(BINARY(1), hex_Value)% 2))                            -- BIT
                  WHEN system_type_id=62
                  THEN RTRIM(
                            LTRIM(
                                 STR(
                                    CONVERT(
                                           FLOAT
                                           , SIGN(CAST(CONVERT(VARBINARY(8000), REVERSE(hex_Value)) AS BIGINT))
                                             * (1.0+ (CAST(CONVERT(VARBINARY(8000), REVERSE(hex_Value)) AS BIGINT)& 0x000FFFFFFFFFFFFF)
                                                * POWER(CAST(2 AS FLOAT), -52)
                                               )
                                             * POWER(
                                                    CAST(2 AS FLOAT)
                                                    , ((CAST(CONVERT(VARBINARY(8000), REVERSE(hex_Value)) AS BIGINT)& 0x7ff0000000000000) / EXP(52 * LOG(2))
                                                       -1023
                                                      )
                                                    )
                                           )
                                    , 53
                                    , LEN(hex_Value)
                                    )
                                 )
                            )                                                                                           --- FLOAT
                  WHEN system_type_id=59
                  THEN LEFT(LTRIM(
                                 STR(
                                    CAST(SIGN(CAST(CONVERT(VARBINARY(8000), REVERSE(hex_Value)) AS BIGINT))
                                         * (1.0+ (CAST(CONVERT(VARBINARY(8000), REVERSE(hex_Value)) AS BIGINT)& 0x007FFFFF) * POWER(CAST(2 AS REAL), -23))
                                         * POWER(CAST(2 AS REAL)
                                                 , (((CAST(CONVERT(VARBINARY(8000), REVERSE(hex_Value)) AS INT)) & 0x7f800000) / EXP(23 * LOG(2))-127)
                                                ) AS REAL)
                                    , 23
                                    , 23
                                    )
                                 ), 8)                                                                                  --Real
                  WHEN system_type_id IN ( 165, 173 )
                  THEN (CASE WHEN CHARINDEX(0x, CAST('' AS XML).value('xs:hexBinary(sql:column("hex_Value"))', 'VARBINARY(8000)'))=0
                             THEN '0x'
                            ELSE ''
                        END
                       ) +CAST('' AS XML).value('xs:hexBinary(sql:column("hex_Value"))', 'varchar(max)')                -- BINARY,VARBINARY
                  WHEN system_type_id=36
                  THEN CONVERT(VARCHAR(MAX), CONVERT(UNIQUEIDENTIFIER, hex_Value))                                      --UNIQUEIDENTIFIER
              END AS FieldValue
            , [RowLogContents]
            , [Transaction ID]
            , [Slot ID]
            , [ID]
    FROM    CTE
    ORDER BY nullbit

    /*Create Update statement*/
    /*Now we have the modified and actual data as well*/
    /*We need to create the update statement in case of recovery*/
    ;

    WITH
    CTE AS (SELECT  (CASE WHEN system_type_id IN ( 167, 175, 189 )
                          THEN QUOTENAME([D].[name])+'='+ISNULL(+''''+[A].[FieldValue]+'''', 'NULL')+' ,'+' '
                         WHEN system_type_id IN ( 231, 239 )
                         THEN QUOTENAME([D].[name])+'='+ISNULL(+'N'''+[A].[FieldValue]+'''', 'NULL')+' ,'+''
                         WHEN system_type_id IN ( 58, 40, 61, 36 )
                         THEN QUOTENAME([D].[name])+'='+ISNULL(+''''+[A].[FieldValue]+'''', 'NULL')+'  ,'+' '
                         WHEN system_type_id IN ( 48, 52, 56, 59, 60, 62, 104, 106, 108, 122, 127 )
                         THEN QUOTENAME([D].[name])+'='+ISNULL([A].[FieldValue], 'NULL')+' ,'+' '
                     END
                    ) AS [Field]
                    , A.[Slot ID]
                    , A.[Transaction ID] AS [Transaction ID]
                    , 'D' AS [Type]
                    , [A].Rowlogcontents
                    , [A].[NonID]
					, CAST(ISNULL(idx.is_primary_key,0) AS TINYINT) AS IsPrimary
            FROM    #temp_Data AS [A]
                    INNER JOIN #temp_Data AS [B] ON [A].[FieldName]=[B].[FieldName] AND [A].[Slot ID]=[B].[Slot ID]
                                                    --And [A].[Transaction ID]=[B].[Transaction ID]+1
                                                    AND [B].[Transaction ID]=
                                                    (
                                                        SELECT  MIN(CAST([Transaction ID] AS INT)) AS [Transaction ID]
                                                        FROM    #temp_Data AS [C]
                                                        WHERE  [A].[Slot ID]=[C].[Slot ID]
                                                        GROUP BY [Slot ID]
                                                    )
                    INNER JOIN sys.columns [D] ON [D].[object_id]=OBJECT_ID(''+@SchemaName_n_TableName+'') AND  A.[FieldName]=D.[name]
					LEFT JOIN sys.index_columns ixc ON ixc.column_id = D.column_id AND ixc.object_id = d.object_id
					LEFT JOIN sys.indexes idx ON idx.index_id = ixc.index_id AND idx.object_id = D.object_id
            WHERE   ISNULL([A].[FieldValue], '')<>ISNULL([B].[FieldValue], '')
            UNION ALL
            SELECT  (CASE WHEN system_type_id IN ( 167, 175, 189 )
                          THEN QUOTENAME([D].[name])+'='+ISNULL(+''''+[A].[FieldValue]+'''', 'NULL')+' AND '+''
                         WHEN system_type_id IN ( 231, 239 )
                         THEN QUOTENAME([D].[name])+'='+ISNULL(+'N'''+[A].[FieldValue]+'''', 'NULL')+' AND '+''
                         WHEN system_type_id IN ( 58, 40, 61, 36 )
                         THEN QUOTENAME([D].[name])+'='+ISNULL(+''''+[A].[FieldValue]+'''', 'NULL')+' AND '+''
                         WHEN system_type_id IN ( 48, 52, 56, 59, 60, 62, 104, 106, 108, 122, 127 )
                         THEN QUOTENAME([D].[name])+'='+ISNULL([A].[FieldValue], 'NULL')+' AND '+''
                     END
                    ) AS [Field]
                    , A.[Slot ID]
                    , A.[Transaction ID] AS [Transaction ID]
                    , 'S' AS [Type]
                    , [A].Rowlogcontents
                    , [A].[NonID]
					, CAST(ISNULL(idx.is_primary_key,0) AS TINYINT) AS IsPrimary
            FROM    #temp_Data AS [A]
                    INNER JOIN #temp_Data AS [B] ON [A].[FieldName]=[B].[FieldName]
                                                    AND [A].[Slot ID]=[B].[Slot ID]
                                                    --And [A].[Transaction ID]=[B].[Transaction ID]+1
                                                    AND [B].[Transaction ID]=
                                                    (
                                                        SELECT  MIN(CAST([Transaction ID] AS INT)) AS [Transaction ID]
                                                        FROM    #temp_Data AS [C]
                                                        WHERE  [A].[Slot ID]=[C].[Slot ID]
                                                        GROUP BY [Slot ID]
                                                    )
                    INNER JOIN sys.columns [D] ON [object_id]=OBJECT_ID(''+@SchemaName_n_TableName+'') AND  [A].[FieldName]=D.[name]
					LEFT JOIN sys.index_columns ixc ON ixc.column_id = D.column_id AND ixc.object_id = d.object_id
					LEFT JOIN sys.indexes idx ON idx.index_id = ixc.index_id AND idx.object_id = D.object_id
            WHERE   ISNULL([A].[FieldValue], '')=ISNULL([B].[FieldValue], '')
                    AND A.[Transaction ID] NOT IN
                        (
                            SELECT  MIN(CAST([Transaction ID] AS INT)) AS [Transaction ID]
                            FROM    #temp_Data AS [C]
                            WHERE   [A].[Slot ID]=[C].[Slot ID]
                            GROUP BY [Slot ID]
                        ))
	, CTEUpdateQuery AS (
		SELECT 'UPDATE '+@SchemaName_n_TableName+' SET ' 
			+ LEFT(STRING_AGG(IIF(a.Type = 'D', A.Field,''),''),LEN(STRING_AGG(IIF(a.Type = 'D', A.Field,''),''))-1) 
			+ '  WHERE  ' + LEFT(STRING_AGG(IIF(a.Type = 'S' AND A.IsPrimary = B.IsPrimary, A.Field,''),'')
								, LEN(STRING_AGG(IIF(a.Type = 'S' AND A.IsPrimary = B.IsPrimary, A.Field,''),''))-3) AS [Update Statement]
			, [A].[Slot ID], [A].[Transaction ID], A.Rowlogcontents, [A].[NonID]
		FROM CTE A
			LEFT JOIN (
				SELECT [Transaction ID], [Slot ID], MAX(IsPrimary) IsPrimary
				FROM CTE 
				GROUP BY CTE.[Transaction ID], CTE.[Slot ID]
			) B ON B.[Slot ID] = A.[Slot ID] AND B.[Transaction ID] = A.[Transaction ID]
		GROUP BY [A].[Slot ID], [A].[Transaction ID], A.Rowlogcontents, [A].[NonID])
    --SELECT   'UPDATE '+@SchemaName_n_TableName+' SET '+LEFT(STUFF((
    --                                                                                     SELECT ' '+ISNULL([Field], '')+' '
    --                                                                                     FROM   CTE B
    --                                                                                     WHERE  A.[Slot ID]=B.[Slot ID]
    --                                                                                            AND A.[Transaction ID]=B.[Transaction ID]
    --                                                                                            AND B.[Type]='D'
    --                                                                                     FOR XML PATH('')
    --                                                                                 )
    --                                                                                 , 1
    --                                                                                 , 1
    --                                                                                 , ''
    --                                                                                ), LEN(STUFF((
    --                                                                                                 SELECT ' '+ISNULL([Field], '')+' '
    --                                                                                                 FROM   CTE B
    --                                                                                                 WHERE A.[Slot ID]=B.[Slot ID]
    --                                                                                                       AND A.[Transaction ID]=B.[Transaction ID]
    --                                                                                                       AND B.[Type]='D'
    --                                                                                                 FOR XML PATH('')
    --                                                                                             )
    --                                                                                             , 1
    --                                                                                             , 1
    --                                                                                             , ''
    --                                                                                            )
    --                                                                                      )-2)+'  WHERE  '
    --                            +LEFT(STUFF((
    --                                            SELECT      ' '+ISNULL([Field], '')+' '
    --                                            FROM    CTE C
    --                                            WHERE A.[Slot ID]=C.[Slot ID]
    --                                                  AND A.[Transaction ID]=C.[Transaction ID]
    --                                                  AND C.[Type]='S'
    --                                            FOR XML PATH('')
    --                                        )
    --                                        , 1
    --                                        , 1
    --                                        , ''
    --                                       ), LEN(STUFF((
    --                                                        SELECT  ' '+ISNULL([Field], '')+' '
    --                                                        FROM    CTE C
    --                                                        WHERE   A.[Slot ID]=C.[Slot ID]
    --                                                                AND A.[Transaction ID]=C.[Transaction ID]
    --                                                                AND C.[Type]='S'
    --                                                        FOR XML PATH('')
    --                                                    )
    --                                                    , 1
    --                                                    , 1
    --                                                    , ''
    --                                                   )
    --                                             )-4) AS [Update Statement]
    --                            , [Slot ID]
    --                            , [Transaction ID]
    --                            , Rowlogcontents
    --                            , [A].[NonID]
    --                   FROM CTE A
    --                   GROUP BY [Slot ID], [Transaction ID], Rowlogcontents, [A].[NonID])
    INSERT INTO #temp_Data
    SELECT  'Update Statement', ISNULL([Update Statement], ''), [Rowlogcontents], [Transaction ID], [Slot ID], [NonID]
    FROM    CTEUpdateQuery;

    /**************************/
    --Create the column name in the same order to do pivot table.
    DECLARE @FieldName VARCHAR(MAX);

    SET @FieldName=STUFF((
                             SELECT ','+CAST(QUOTENAME([name]) AS VARCHAR(MAX))
                             FROM   syscolumns
                             WHERE  id=OBJECT_ID(''+@SchemaName_n_TableName+'')
                             FOR XML PATH('')
                         )
                         , 1
                         , 1
                         , ''
                        );

    --Finally did pivot table and got the data back in the same format.
    --The [Update Statement] column will give you the query that you can execute in case of recovery.
    SET @SQL
        =N'SELECT '+@FieldName+N',[Update Statement] FROM #temp_Data
PIVOT (Min([FieldValue]) FOR FieldName IN ('+@FieldName
         +N',[Update Statement])) AS pvt
Where [Transaction ID] NOT In (Select Min(Cast([Transaction ID] as int)) as [Transaction ID] from #temp_Data
Group By [Slot ID]) ORDER BY Convert(int,[Slot ID]),Convert(int,[Transaction ID])';

    PRINT @SQL;

    EXEC sp_executesql @SQL;

	DROP TABLE IF EXISTS #temp_Data	
END;
GO
