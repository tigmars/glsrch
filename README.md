# glsrch
To find the customer with CustomerID = 'QUEEN' in the northwind database, you might use this query:
SELECT * FROM dbo.Customers WHERE CompanyName LIKE '%Cozinha%'

The resulting query plan is a clustered index scan.  The goal is to do better.
Objectives:
- Always use an index seek
- Locate a record by searching not only fields in its table but also by related tables.
- Adapt to any database via configuration and no coding.
- Support a page forward/back interface with a stored procedure that caches the results of a search.

The included example runs on the Northwnd database.  (Note the missing 'i'.)
- Open sqlsug.sql in SSMS.  F5
- Open sqlsug_run.sql in SSMS. F5