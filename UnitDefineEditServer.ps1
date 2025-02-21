# 引数に2つのファイルパス(拡張子は.ajs)を受け取り、Webサーバーを作成して1つ目のファイルをそのままレスポンスとして返すサーバーを作成する
param (
    [Parameter(Mandatory=$true)]
    [string]$filePath1,

    [Parameter(Mandatory=$true)]
    [string]$filePath2
)

# 1つ目のファイルパスにファイルが存在するかチェックする(2つ目は存在しなくてよい)
if (-Not (Test-Path $filePath1)) {
    Write-Error "The specified file $filePath1 does not exist."
    exit 1
}

$rootUnit = $null

# シンプルなHTTPサーバーを作成する
$port = 8080
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Output "Listening on port $port..."

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    if ($request.HttpMethod -eq "GET") {
        $response.ContentType = 'text/html; charset=Shift_JIS'
        $response.StatusCode = 200

        # SJISで作成された1つ目のファイルを1行ずつ読み込み、入れ子構造のユニット情報を取得する
        # - "unit="で始まる行は、次行から始まる{ ... }セクションのサマリであり、カンマ区切りである右辺の1項目目がユニット名
        #  - 例 unit=GA,,jp1usr01,;
        # - { ... }セクション内の"cm="で始まる行がユニットのコメント
        #  - 例 	cm="固定資産税（土地・家屋）";
        # - { ... }セクション内に"unit="で始まる行がある場合、次行からネストされた{ ... }セクションが始まる
        # - { ... }セクション内はタブでインデントされ、ネスト数分のタブが先頭に付加される
        $rootUnit = @{
            Name = 'Root'
            Comment = $null
            NestedUnits = @()
            ParentUnit = $null
        }
        $currentUnit = $rootUnit

        Get-Content -Path $filePath1 | ForEach-Object {
            if ($_ -match '^\t*unit=') {
                $parentUnit = $currentUnit
                $currentUnit = @{
                    Name = ($_ -split ',')[0] -replace '^\t*unit='
                    Comment = $null
                    NestedUnits = @()
                    ParentUnit = $parentUnit
                }
            } elseif ($_ -match '^\t*\}') {
                $currentUnit.ParentUnit.NestedUnits += $currentUnit
                $currentUnit = $currentUnit.ParentUnit
            } elseif ($_ -match '^\t*cm=') {
                $currentUnit.Comment = ($_ -replace '^\t*cm=' -replace '"|;', '').Trim()
            }
        }

        # 入れ子構造のユニット情報をul, li, details, summaryを用いたHTML形式でレスポンスとして返す
        function Convert-UnitToHtml {
            param (
                [hashtable]$unit
            )

            $html = ""
            $html += "<li>`n"
            $html += "<details open>`n"
            $html += "<summary>$($unit.Name):$($unit.Comment)</summary>`n"
            $html += "<ul>`n"
            foreach ($nestedUnit in $unit.NestedUnits) {
                $html += Convert-UnitToHtml -unit $nestedUnit
            }
            $html += "</ul>`n"
            $html += "</details>`n"
            $html += "</li>`n"
            return $html
        }

        $htmlContent = "<html><body>"
        $htmlContent = "<form method='post'><input type='submit' value='Save'></form>"
        $htmlContent += "<ul>"
        $htmlContent += Convert-UnitToHtml -unit $rootUnit
        $htmlContent += "</ul></body></html>"

        $buffer = [System.Text.Encoding]::GetEncoding("Shift_JIS").GetBytes($htmlContent)
        $response.ContentLength64 = $buffer.Length
        $response.OutputStream.Write($buffer, 0, $buffer.Length)
        $response.OutputStream.Flush()
        $response.OutputStream.Close()
    } elseif ($request.HttpMethod -eq "POST") {
        $response.StatusCode = 200
        $response.Close()

        # $rootUnitのNestedUnitsを再帰的に辿りながら、NameとCommentをフォーマットして$filePath2に逐次書き出す
        function Write-UnitToFile {
            param (
                [hashtable]$unit,
                [int]$depth,
                [System.IO.StreamWriter]$writer
            )

            $writer.WriteLine("`t" * $depth + "unit=$($unit.Name),;")
            $writer.WriteLine("`t" * $depth + "{")
            $writer.WriteLine("`t" * ($depth + 1) + "cm=`"$($unit.Comment)`";")
            foreach ($nestedUnit in $unit.NestedUnits) {
                Write-UnitToFile -unit $nestedUnit -depth ($depth + 1) -writer $writer
            }
            $writer.WriteLine("`t" * $depth + "}")
        }

        $writer = [System.IO.StreamWriter]::new($filePath2, $false, [System.Text.Encoding]::GetEncoding("Shift_JIS"))
        Write-UnitToFile -unit $rootUnit.NestedUnits[0] -depth 0 -writer $writer
        $writer.Close()
    }
}
$listener.Stop()
Write-Output "Server stopped."