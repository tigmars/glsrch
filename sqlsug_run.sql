
DECLARE @employee_inputs XML = '
<paths table="Northwnd.dbo.Employees" key="EmployeeID">
	<path table="Northwnd.dbo.Employees" key="EmployeeID" column="LastName"/>
	<path table="Northwnd.dbo.Employees" key="EmployeeID" column="FirstName"/>
	<path table="Northwnd.dbo.Territories" key="TerritoryID" column="TerritoryDescription">
		<path table="Northwnd.dbo.EmployeeTerritories" key="EmployeeID">
			<path table="Northwnd.dbo.Employees" key="EmployeeID"/>
		</path>
	</path>	
</paths>
';

DECLARE @product_inputs XML='
<paths table="Northwnd.dbo.Products" key="ProductID">
	<path table="Northwnd.dbo.Products" key="ProductID" column="ProductName"/>
</paths>
'

DECLARE @supplier_inputs XML = '
<paths table="Northwnd.dbo.Suppliers" key="SupplierID">
	<path table="Northwnd.dbo.Suppliers" key="SupplierID" column="CompanyName"/>
	<path table="Northwnd.dbo.Products" key="SupplierID" column="ProductName" keycol="ProductID">
		<path table="Northwnd.dbo.Suppliers" key="SupplierID"/>
	</path>
</paths>
'

TRUNCATE TABLE glsrch.SearchIndex;
EXEC glsrch.LoadConfig @inputs = @employee_inputs;
EXEC glsrch.LoadConfig @inputs = @product_inputs;
EXEC glsrch.LoadConfig @inputs = @supplier_inputs;



-- This is optional.  If you don't have this stored proc, just comment it out.
-- It comes from Ola Hallengren.  If you've never heard of it, you should google
-- it because it's an interesting part of TSQL culture.
EXECUTE master.[dbo].[IndexOptimize] @Databases = 'Northwnd' ,
                                     @UpdateStatistics = 'ALL';


