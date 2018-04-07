/*
Copyright CNC Software, Inc. 2018
*/
USE SqlUsers;
GO
SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

DROP FUNCTION IF EXISTS tokens.Tokenize;
DROP FUNCTION IF EXISTS tokens.RemovePunctuation;
DROP TABLE IF EXISTS glsrch.SearchIndex;
DROP TABLE IF EXISTS glsrch.CachedSearchResult;
DROP TABLE IF EXISTS [glsrch].[CachedSearch];
DROP TABLE IF EXISTS [tokens].[SkipWords];
GO
DROP TABLE IF EXISTS tokens.Punctuation;
GO


DROP PROC IF EXISTS glsrch.TreeWalk;
DROP PROC IF EXISTS glsrch.CacheSearch;
DROP PROC IF EXISTS glsrch.LoadConfig;
DROP TYPE IF EXISTS [glsrch].[PathTableType];
DROP SCHEMA IF EXISTS glsrch;

DROP SCHEMA IF EXISTS tokens;
EXEC sys.sp_executesql N'CREATE SCHEMA glsrch';
EXEC sys.sp_executesql N'CREATE SCHEMA tokens';


CREATE TYPE [glsrch].[PathTableType] AS TABLE
    (
        [Id] [INT] IDENTITY(1, 1) NOT NULL ,
        [Table] [NVARCHAR](100) NULL ,
        [Key] [NVARCHAR](100) NULL ,
        [Column] [NVARCHAR](100) NULL ,
        [Paths] [XML] NULL ,
        [Level] [INT] NULL ,
        PRIMARY KEY CLUSTERED ( [Id] ASC )
        WITH ( IGNORE_DUP_KEY = OFF )
    );
GO

CREATE PROCEDURE [glsrch].[TreeWalk]
    (
        @Paths [glsrch].[PathTableType] READONLY ,
        @QueryIn NVARCHAR(MAX) ,
        @QueryOut NVARCHAR(MAX) OUTPUT ,
        @PrevTab NVARCHAR(128) = NULL ,
        @PrevKey NVARCHAR(128) = NULL
    )
AS
    BEGIN
        SET NOCOUNT ON;
        IF NOT EXISTS (   SELECT t.Id
                          FROM   @Paths t
                                 CROSS APPLY t.Paths.nodes('/path') t1(paths)
                      )
            BEGIN
                SET @QueryOut = @QueryIn; --+ ';';
                RETURN;
            END;

        DECLARE @tab NVARCHAR(100);
        DECLARE @key NVARCHAR(100);
        DECLARE @col NVARCHAR(100);
        DECLARE @keycol NVARCHAR(100);
        DECLARE @lev INT;
        DECLARE @pat XML;

        SELECT @tab = p.[Table] ,
               @key = p.[Key]
        FROM   @Paths p;
        DECLARE @t glsrch.PathTableType;
        DECLARE @Query NVARCHAR(MAX);
        DECLARE @QO NVARCHAR(MAX);

        DECLARE pcurs CURSOR LOCAL FOR
            SELECT t1.Paths.value('@table', 'sysname') ,
                   t1.Paths.value('@key', 'sysname') ,
                   t1.Paths.value('@column', 'sysname') ,
                   t1.Paths.value('@keycol', 'sysname') ,
                   t1.Paths.query('path') ,
                   t.Level
            FROM   @Paths t
                   CROSS APPLY t.Paths.nodes('/path') t1(paths);

        OPEN pcurs;
        FETCH NEXT FROM pcurs
        INTO @tab ,
             @key ,
             @col ,
             @keycol ,
             @pat ,
             @lev;

        IF @lev <> 1
            BEGIN
                SET @QueryOut = @QueryIn + ' JOIN ' + @tab + ' ON ' + @tab
                                + '.' + @PrevKey + ' = ' + @PrevTab + '.'
                                + @PrevKey;
            END;

        WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @lev = 1
                    BEGIN
                        SET @keycol = ISNULL(@keycol, @key);
                        SET @QueryOut = ISNULL(@QueryOut, '')
                                        + 'INSERT glsrch.SearchIndex (TableToSearch , KeyToLocate , ValueColumn , ValueComesFrom, Position, ValueComesFromKey) '
                                        + ' SELECT ' + '''' + @PrevTab + '.'
                                        + @PrevKey + ''', ' + @PrevTab + '.'
                                        + @PrevKey + ', T.ValueColumn, '
                                        + ' ''' + @tab + '.' + @col + ''', '
                                        + ' T.Pos, ' + @tab + '.' + @keycol
                                        + ' FROM ' + @tab
                                        + ' CROSS APPLY tokens.Tokenize('
                                        + @tab + '.' + @col + ', '' '') T ';

                    END;

                INSERT @t (   [Table] ,
                              [Key] ,
                              [Column] ,
                              [Paths] ,
                              [Level]
                          )
                VALUES ( @tab, @key, @col, @pat, @lev + 1 );
                EXEC glsrch.TreeWalk @Paths = @t ,
                                     @QueryIn = @QueryOut ,
                                     @QueryOut = @QO OUTPUT ,
                                     @PrevTab = @tab ,
                                     @PrevKey = @key;
                DELETE @t;

                IF @lev = 1
                    BEGIN
                        SET @QueryOut = @QO + ' WHERE ' + @tab + '.' + @col
                                        + ' IS NOT NULL AND ' + @tab + '.'
                                        + @col
                                        + ' <> '''' AND T.ValueColumn <> '''' ';
                    END;
                ELSE
                    BEGIN
                        SET @QueryOut = @QO;
                    END;

                FETCH NEXT FROM pcurs
                INTO @tab ,
                     @key ,
                     @col ,
                     @keycol ,
                     @pat ,
                     @lev;

            END;

        CLOSE pcurs;
        DEALLOCATE pcurs;
    END;

GO

-- WARNING:  If you change anything inside this stored proc you have to
-- look at the query plan and sure that the statement that INSERTs into
-- #tmptbl is using an index seek instead of an index scan.  That's the 
-- thing that distinguishes the performance of this searching strategy
-- with the old one that used '%' before and after the search string.
-- If the plan uses a scan, then the search takes just as long as the other one.

CREATE PROCEDURE [glsrch].[CacheSearch]
    (
        @SearchFor NVARCHAR(200)
    )
AS
    BEGIN

        SET NOCOUNT ON;

        CREATE TABLE #tmptbl
            (
                tmpTblId INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED NOT NULL ,
                [Key] INT NOT NULL ,
                SearchTerm NVARCHAR(50) NOT NULL ,
                SearchTermType NVARCHAR(128) NOT NULL ,
                id INT NOT NULL ,
                PositionInUserInput INT NOT NULL ,
                [Deleted] BIT NOT NULL
                    DEFAULT 0 ,
                [Found] NVARCHAR(128) NOT NULL
            );
        CREATE NONCLUSTERED INDEX ix_tmptbl_key
            ON #tmptbl
            (
                [Key] ,
                SearchTermType
            )
            INCLUDE ( [Deleted] );
        CREATE NONCLUSTERED INDEX ix_tmptbl_keyterm
            ON #tmptbl
            (
                [Key] ,
                SearchTerm ,
                SearchTermType
            )
            INCLUDE ( [Deleted] );
        CREATE NONCLUSTERED INDEX ix_tmptbl_SearchTerm
            ON #tmptbl
            (
                SearchTerm ,
                SearchTermType
            )
            INCLUDE
            (
                [Deleted] ,
                PositionInUserInput
            );
        CREATE NONCLUSTERED INDEX ix_tmptbl_SearchTermType
            ON #tmptbl
            (
                SearchTermType ,
                PositionInUserInput
            )
            INCLUDE
            (
                [Deleted] ,
                id ,
                SearchTerm ,
                [Key]
            );
        -- Seems as if the table should have this index however the query
        -- plan analyzer says that it takes a lot of extra time to keep the
        -- index updated.  Removing the index gets around that although it 
        -- does require an extra sort in the plan.
        --CREATE NONCLUSTERED INDEX IX_tmptbl ON #tmptbl ([Key], SearchTerm)

        BEGIN TRY

            -- Logically, it's not necessary to use a tmp table here.  I'm using
            -- it anyway in order to convince the query optimizer to use an 
            -- index seek.  As soon as I added the '%' onto the end of ValueColumn,
            -- the optimizer switched to a scan and the only trick I found was
            -- to use the temp table.
            CREATE TABLE #ttok
                (
                    [Pos] INT IDENTITY(1, 1) ,
                    ValueColumn NVARCHAR(50)
                );
            CREATE NONCLUSTERED INDEX ttok_valuecolumn
                ON #ttok ( ValueColumn );

            INSERT #ttok ( ValueColumn )
                   SELECT ValueColumn
                   FROM   tokens.Tokenize(@SearchFor, ' ');

            -- Experimental.  Because of the way the UI works, maybe we should
            -- limit the results to the items that match on the same number of
            -- terms in the user's search.  For a google-like search, this is not
            -- the right thing to do.
            DECLARE @PassedInTokenCount INT = @@IDENTITY;

            INSERT #tmptbl (   [Key] ,
                               SearchTerm ,
                               SearchTermType ,
                               id ,
                               PositionInUserInput ,
                               Found
                           )
                   SELECT C.KeyToLocate ,
                          C.ValueColumn ,
                          C.ValueComesFrom ,
                          C.ValueComesFromKey ,
                          tt.Pos ,
                          C.TableToSearch
                   FROM   glsrch.SearchIndex C
                          JOIN #ttok tt ON C.ValueColumn = tt.ValueColumn; --LIKE tt.ValueColumn + '%'

            -- Remove duplicates.  This means that if a company matches twice on 1 search term
            -- then we'll remove one of those 2 matches.  Reason:  If the user enters 3 search
            -- terms for example, we want to ensure that we match on all 3 terms.
            --DELETE #tmptbl
            UPDATE #tmptbl
            SET    [Deleted] = 1
            WHERE  tmpTblId IN (   SELECT tmpTblId
                                   FROM   (   SELECT tmpTblId ,
                                                     ROW_NUMBER() OVER (PARTITION BY [Key] ,
                                                                                  SearchTerm ,
                                                                                  SearchTermType ORDER BY [Key] ,
                                                                                  SearchTerm ,
                                                                                  SearchTermType 
                                                                   ) AS dupcheck
                                              FROM   #tmptbl
                                          ) AS X
                                   WHERE  dupcheck > 1
                               );

            SELECT   GoodMatches.[Key] ,
                     GoodMatches.id ,
                     GoodMatches.SearchTerm ,
                     GoodMatches.SearchTermType ,
                     GoodMatches.Found ,
                     ROW_NUMBER() OVER ( PARTITION BY GoodMatches.[Key] ,
                                                      GoodMatches.SearchTermType
                                         ORDER BY GoodMatches.[Key] ,
                                                  GoodMatches.SearchTermType DESC ,
                                                  GoodMatches.PositionInUserInput
                                       )
            FROM     (   SELECT Matches.[Key] ,
                                SearchTerm ,
                                SearchTermType ,
                                id ,
                                tt.PositionInUserInput ,
                                tt.Found
                         FROM   #tmptbl tt
                                JOIN (   SELECT   [Key]
                                         FROM     #tmptbl
                                         WHERE    [Deleted] = 0
                                         GROUP BY [Key]
                                         HAVING   COUNT(*) >= @PassedInTokenCount
                                     ) AS Matches ON tt.[Key] = Matches.[Key]
                         WHERE  [tt].[Deleted] = 0
                     ) AS GoodMatches
            ORDER BY GoodMatches.[Key] ,
                     GoodMatches.SearchTermType DESC;



        END TRY
        BEGIN CATCH

            DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
            DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
            DECLARE @ErrorState INT = ERROR_STATE();

            RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
        END CATCH;

        DROP TABLE #tmptbl;

    END;

GO


CREATE FUNCTION [tokens].[RemovePunctuation]
    (
        @string AS NVARCHAR(200)
    )
RETURNS NVARCHAR(200)
AS
    BEGIN
		-- SQL Prompt formatting off 
        DECLARE @replaced NVARCHAR(200) = replace(replace(replace(@string,' ','<>'),'><',''),'<>',' ')
		-- SQL Prompt formatting on
        RETURN @replaced;
    END;
GO


CREATE FUNCTION [tokens].[Tokenize]
    (
        @String1 NVARCHAR(1000) ,
        @Delimiter NVARCHAR(1)
    )
RETURNS @List TABLE
    (
        ValueColumn NVARCHAR(128) NULL ,
        Pos INT
    )
AS
    BEGIN
        DECLARE @String NVARCHAR(MAX);
        SET @String = ' ' + tokens.RemovePunctuation(@String1) + ' ';

		-- SQL Prompt formatting off 
        INSERT  @List (ValueColumn, Pos)
                SELECT  SUBSTRING(@String, N+1, CHARINDEX(@Delimiter, @String, N+1) - N - 1) , N
                FROM    ( SELECT TOP (LEN(@string)) ROW_NUMBER() OVER ( ORDER BY n ) AS N
                          FROM      dbo.GetNums(1, 128)
                        ) AS X
                WHERE   N < LEN(@String) AND SUBSTRING(@String, N, 1) = @Delimiter
		-- SQL Prompt formatting on
        RETURN;
    END;


GO



CREATE TABLE [tokens].[SkipWords]
    (
        Id INT IDENTITY(1, 1) NOT NULL ,
        [Word] [NVARCHAR](32) NOT NULL
    );
GO
ALTER TABLE tokens.SkipWords
ADD CONSTRAINT PK_SkipWords_Id
    PRIMARY KEY CLUSTERED ( Id );

INSERT tokens.SkipWords ( Word )
VALUES ( ' - ' ) ,
    ( ' and ' ) ,
    ( ' co ' ) ,
    ( ' de ' ) ,
    ( ' inc ' ) ,
    ( ' incorporated ' ) ,
    ( ' llc ' ) ,
    ( ' ltd ' ) ,
    ( ' of ' ) ,
    ( ' pvt ' ) ,
    ( ' the ' );

CREATE TABLE [tokens].[Punctuation]
    (
        Id INT IDENTITY(1, 1) NOT NULL ,
        [Symbol] [NVARCHAR](1) NOT NULL
    );

GO
ALTER TABLE tokens.Punctuation
ADD CONSTRAINT PK_Punctuation_Id
    PRIMARY KEY CLUSTERED ( Id );

INSERT tokens.Punctuation ( Symbol )
VALUES ( '"' ) ,
    ( '#' ) ,
    ( '&' ) ,
    ( '&' ) ,
    ( '(' ) ,
    ( ')' ) ,
    ( '*' ) ,
    ( ',' ) ,
    ( '.' ) ,
    ( '/' ) ,
    ( ':' ) ,
    ( ';' ) ,
    ( '?' ) ,
    ( '@' ) ,
    ( '[' ) ,
    ( ']' ) ,
    ( '^' ) ,
    ( '{' ) ,
    ( '|' ) ,
    ( '}' ) ,
    ( '+' ) ,
    ( '<' ) ,
    ( '=' ) ,
    ( '>' );

GO

CREATE TABLE [glsrch].[CachedSearch]
    (
        [CachedSearchID] [INT] IDENTITY(1, 1) NOT NULL ,
        [SearchTerms] [NVARCHAR](128) NOT NULL ,
        [LastUsed] [DATETIME] NOT NULL ,
        [Created] [DATETIME] NOT NULL ,
    );
GO
ALTER TABLE [glsrch].[CachedSearch]
ADD CONSTRAINT PK_CachedSearch_CachedSearchID
    PRIMARY KEY CLUSTERED ( CachedSearchID );

ALTER TABLE [glsrch].[CachedSearch]
ADD CONSTRAINT [DF_CachedSearch_LastUsed]
DEFAULT ( GETDATE()) FOR [LastUsed];
GO

ALTER TABLE [glsrch].[CachedSearch]
ADD CONSTRAINT [DF_CachedSearch_Created]
DEFAULT ( GETDATE()) FOR [Created];

GO


CREATE TABLE [glsrch].[SearchIndex]
    (
        [SearchIndexID] BIGINT IDENTITY(1, 1) NOT NULL ,
        [TableToSearch] [NVARCHAR](128) NOT NULL ,
        [KeyToLocate] [INT] NOT NULL ,
        [ValueColumn] [NVARCHAR](200) NOT NULL ,
        [ValueComesFrom] [NVARCHAR](128) NOT NULL ,
        [Position] INT NOT NULL ,
        [ValueComesFromKey] INT NOT NULL ,
    );
ALTER TABLE glsrch.SearchIndex
ADD CONSTRAINT PK_SearchIndex_SearchIndexID
    PRIMARY KEY CLUSTERED ( SearchIndexID );

CREATE NONCLUSTERED INDEX [IX_SearchIndex_ValueColumn]
    ON [glsrch].[SearchIndex] ( [ValueColumn] )
    INCLUDE
    (
        [KeyToLocate] ,
        [ValueComesFrom] ,
        [ValueComesFromKey]
    );
GO

CREATE TABLE glsrch.CachedSearchResult
    (
        CachedSearchResultID INT IDENTITY(1, 1) NOT NULL ,
        CachedSearchID INT NOT NULL ,
        [Key] INT NOT NULL ,
        [Id] INT NOT NULL ,
        SearchTermType NVARCHAR(200) NOT NULL ,
        MatchedOn NVARCHAR(100) NOT NULL ,
        Position INT NOT NULL
    );
GO
ALTER TABLE glsrch.CachedSearchResult
ADD CONSTRAINT PL_CachedSearchResult_CachedSearchResultID
    PRIMARY KEY CLUSTERED ( CachedSearchResultID );
GO

CREATE PROC glsrch.LoadConfig
    (
        @inputs XML
    )
AS
    BEGIN
        SET NOCOUNT ON;

        DROP TABLE IF EXISTS #t;
        CREATE TABLE #t
            (
                [Table] NVARCHAR(50) ,
                [Column] NVARCHAR(50) ,
                [Key] NVARCHAR(50) ,
                [Paths] XML
            );

        INSERT #t
               SELECT p.c.value('@table', 'sysname') ,
                      p.c.value('@column', 'sysname') ,
                      p.c.value('@key', 'sysname') ,
                      p.c.query('path')
               FROM   @inputs.nodes('/paths')p(c);

        DECLARE @t glsrch.PathTableType;
        DECLARE @tab sysname;
        DECLARE @key sysname;
        DECLARE @col sysname;
        DECLARE @paths XML;


        SELECT @tab = t.[Table] ,
               @key = t.[Key] ,
               @col = t.[Column] ,
               @paths = t.Paths
        FROM   #t t;

        DECLARE @QueryOut NVARCHAR(MAX);

        INSERT @t (   [Table] ,
                      [Key] ,
                      [Column] ,
                      [Paths] ,
                      [Level]
                  )
        VALUES ( @tab, @key, @col, @paths, 1 );

        EXEC glsrch.TreeWalk @Paths = @t ,
                             @QueryIn = ' ' ,
                             @QueryOut = @QueryOut OUT ,
                             @PrevTab = @tab ,
                             @PrevKey = @key;

        SELECT @QueryOut;
		ALTER INDEX IX_SearchIndex_ValueColumn ON glsrch.SearchIndex DISABLE
        EXEC sp_executesql @QueryOut;
		ALTER INDEX IX_SearchIndex_ValueColumn ON glsrch.SearchIndex REBUILD

    END;
GO
