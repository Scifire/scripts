#Parameter
$Path = "C:\Temp"
 
Get-ChildItem -Path $Path -Force -Recurse -Directory |
    Where-Object { (Get-ChildItem -Path $_.FullName -Recurse -File -EA SilentlyContinue |
        Measure-Object).Count -eq 0 } | Remove-Item -Force -Recurse
