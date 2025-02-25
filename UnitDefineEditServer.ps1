# 引数にドキュメントルートディレクトリパスを受け取る
param (
    [Parameter(Mandatory=$true)][string]$documentRootDirectoryPath
)

# ディレクトリパスにディレクトリが存在するかチェックする
if (-Not (Test-Path $documentRootDirectoryPath)) {
    Write-Error "The specified directory $documentRootDirectoryPath does not exist."
    exit 1
}

$rootUnit = $null

# HTTPサーバーを作成する
$publishUrl = "http://localhost:8090/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($publishUrl)
$listener.Start()
Write-Output "Listening on port $publishUrl..."
start $publishUrl

function Send-Response {
    param (
        [string]$filename,
        [string]$htmlContent,
        [System.Net.HttpListenerResponse]$response
    )

    $targetHtmlPath = Join-Path -Path $PSScriptRoot -ChildPath $filename
    $targetHtmlContent = Get-Content -Path $targetHtmlPath
    $targetHtmlContent = $targetHtmlContent -replace '\$\{htmlContent\}', $htmlContent

    $buffer = [System.Text.Encoding]::GetEncoding("Shift_JIS").GetBytes($targetHtmlContent)
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Flush()
    $response.OutputStream.Close()
}

while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response

    if ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/") {
        # 入れ子構造のディレクトリ, ajsファイルをul, li, details, summaryを用いたHTML形式でレスポンスとして返す
        function Convert-DirectoryToHtml {
            param ([string]$directoryPath)
            # ディレクトリの再帰的な下位にajsファイルが1つも存在しない場合は、空の文字列を返す
            if ((Get-ChildItem -Path $directoryPath -Recurse -Filter "*.ajs").Count -eq 0) { return "" }

            $html = "<li><details><summary>$(Split-Path -Leaf $directoryPath)</summary><ul>`n"
            Get-ChildItem -Path $directoryPath | ForEach-Object {
                if ($_.PSIsContainer) {
                    $html += Convert-DirectoryToHtml -directoryPath $_.FullName
                } elseif ($_.Extension -eq ".ajs") {
                    $relativePath = $_.FullName.Substring($documentRootDirectoryPath.Length).Replace('\', '/')
                    $html += "<li><a href='$relativePath'>$($_.Name)</a></li>`n"
                }
            }
            $html += "</ul></details></li>`n"
            return $html
        }

        Send-Response -filename "index.html" -htmlContent (Convert-DirectoryToHtml $documentRootDirectoryPath) -response $response
        
    } elseif ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match '^/.*\.ajs$') {
        # ドキュメントルートディレクトリパスとリクエストされたファイル名を結合してファイルパスを作成する
        $targetFilePath = Join-Path -Path $documentRootDirectoryPath -ChildPath $request.Url.AbsolutePath.TrimStart('/')
        if (-Not (Test-Path $targetFilePath)) {
            $response.StatusCode = 404
            $response.Close()
            continue
        }
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

        Get-Content -Path $targetFilePath | ForEach-Object {
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

            $html = "<li><details open><summary>$($unit.Name):$($unit.Comment)</summary><ul>`n"
            foreach ($nestedUnit in $unit.NestedUnits) {
                $html += Convert-UnitToHtml -unit $nestedUnit
            }
            $html += "</ul></details></li>`n"
            return $html
        }

        Send-Response -filename "unitinfo.html" -htmlContent (Convert-UnitToHtml -unit $rootUnit.NestedUnits[0]) -response $response

    } elseif ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/end") {
        $response.StatusCode = 200
        $response.Close()
        break

    } elseif ($request.HttpMethod -eq "POST") {
        # ドキュメントルートディレクトリパスとリクエストされたファイル名を結合してファイルパスを作成する
        $targetFilePath = Join-Path -Path $documentRootDirectoryPath -ChildPath $request.Url.AbsolutePath.TrimStart('/')
        Write-Output $targetFilePath

        # ファイルパスの拡張子がajsでない、あるいはファイルが存在しない場合は、404を返す
        if (-Not ($targetFilePath -match '\.ajs$') -or -Not (Test-Path $targetFilePath)) {
            $response.StatusCode = 404
            $response.Close()
            continue
        }

        # $filePath1の拡張子を除いたファイル名のフォルダを作成する
        # すでに存在する場合は、フォルダ内のファイルをすべて削除する
        $folderPath = $targetFilePath -replace '\.ajs$'
        if (-Not (Test-Path $folderPath)) {
            New-Item -ItemType Directory -Path $folderPath > $null
        } else {
            Get-ChildItem -Path $folderPath | Remove-Item -Force
        }

        $targetUnitList = $rootUnit.NestedUnits[0].NestedUnits

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

        # $targetUnitListの要素のName+".ajs"を、上で作成したフォルダに作成し、
        # Write-UnitToFileを用いてユニット情報を書き出す
        foreach ($unit in $targetUnitList) {
            $filePath2 = Join-Path -Path $folderPath -ChildPath "$($unit.Name).ajs"
            $writer = [System.IO.StreamWriter]::new($filePath2, $false, [System.Text.Encoding]::GetEncoding("Shift_JIS"))
            Write-UnitToFile -unit $unit -depth 0 -writer $writer
            $writer.Close()
        }

        $response.StatusCode = 200
        $response.Close()

    } else {
        $response.StatusCode = 404
        $response.Close()
    }
}
$listener.Stop()