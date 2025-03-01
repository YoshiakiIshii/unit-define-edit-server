# 引数にドキュメントルートディレクトリパスを受け取る
param (
    [Parameter(Mandatory = $true)][string]$documentRootDirectoryPath
)

# SJISで作成された1つ目のファイルを1行ずつ読み込み、入れ子構造のユニット情報を取得する
# - "unit="で始まる行は、次行から始まる{ ... }セクションのサマリであり、カンマ区切りである右辺の1項目目がユニット名
#  - 例 unit=GA,,jp1usr01,;
# - { ... }セクション内の"cm="で始まる行がユニットのコメント
#  - 例 	cm="固定資産税（土地・家屋）";
# - { ... }セクション内の"ty="で始まる行がユニット種別定義
# - { ... }セクション内に"unit="で始まる行がある場合、次行からネストされた{ ... }セクションが始まる
# - { ... }セクション内はタブでインデントされ、ネスト数分のタブが先頭に付加される
function Read-UnitFromFile {
    param ([string]$filePath)

    $unit = @{
        NestedUnits = @()
    }
    $currentUnit = $unit

    Get-Content -Path $filePath | ForEach-Object {
        if ($_ -match '^\t*unit=') {
            $parentUnit = $currentUnit
            $currentUnit = @{
                Name        = ($_ -split ',')[0] -replace '^\t*unit='
                UnitDef     = $_ -replace '^\t*'
                Comment     = $null
                UnitType = $null
                Parameters  = @()
                NestedUnits = @()
                ParentUnit  = $parentUnit
            }
        }
        elseif ($_ -match '^\t*\{') {
        }
        elseif ($_ -match '^\t*\}') {
            $currentUnit.ParentUnit.NestedUnits += $currentUnit
            $currentUnit = $currentUnit.ParentUnit
        }
        elseif ($_ -match '^\t*cm=') {
            $currentUnit.Comment = ($_ -replace '^\t*cm=' -replace '"|;').Trim()
            $currentUnit.Parameters += $_ -replace '^\t*'
        }
        elseif ($_ -match '^\t*ty=') {
            $currentUnit.UnitType = ($_ -replace '^\t*ty=' -replace ';').Trim()
            $currentUnit.Parameters += $_ -replace '^\t*'
        }
        else {
            $currentUnit.Parameters += $_ -replace '^\t*'
        }
    }
    return $unit.NestedUnits[0]
}

function Write-UnitToFile {
    param (
        [hashtable]$unit,
        [int]$depth,
        [System.IO.StreamWriter]$writer
    )

    $writer.WriteLine("`t" * $depth + "$($unit.UnitDef)")
    $writer.WriteLine("`t" * $depth + "{")
    foreach ($parameter in $unit.Parameters) {
        $writer.WriteLine("`t" * ($depth + 1) + "$parameter")
    }
    foreach ($nestedUnit in $unit.NestedUnits) {
        Write-UnitToFile -unit $nestedUnit -depth ($depth + 1) -writer $writer
    }
    $writer.WriteLine("`t" * $depth + "}")
}

function Send-Response {
    param (
        [string]$filename,
        [string]$htmlContent,
        [System.Net.HttpListenerResponse]$response
    )

    $response.ContentType = 'text/html; charset=Shift_JIS'
    $response.StatusCode = 200

    $targetHtmlPath = Join-Path -Path $PSScriptRoot -ChildPath $filename
    $targetHtmlContent = Get-Content -Path $targetHtmlPath
    $targetHtmlContent = $targetHtmlContent -replace '\$\{htmlContent\}', $htmlContent

    $buffer = [System.Text.Encoding]::GetEncoding("Shift_JIS").GetBytes($targetHtmlContent)
    $response.ContentLength64 = $buffer.Length
    $response.OutputStream.Write($buffer, 0, $buffer.Length)
    $response.OutputStream.Flush()
    $response.OutputStream.Close()
}

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

            $html = "<li class='folder'><details><summary>$(Split-Path -Leaf $directoryPath)</summary><ul>`n"
            Get-ChildItem -Path $directoryPath | ForEach-Object {
                if ($_.PSIsContainer) {
                    $html += Convert-DirectoryToHtml -directoryPath $_.FullName
                }
                elseif ($_.Extension -eq ".ajs") {
                    $relativePath = $_.FullName.Substring($documentRootDirectoryPath.Length).Replace('\', '/')
                    $html += "<li class='file'><a href='$relativePath'>$($_.Name)</a></li>`n"
                }
            }
            $html += "</ul></details></li>`n"
            return $html
        }

        Send-Response -filename "index.html" -htmlContent (Convert-DirectoryToHtml $documentRootDirectoryPath) -response $response
        
    }
    elseif ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -match '^/.*\.ajs$') {
        # ドキュメントルートディレクトリパスとリクエストされたファイル名を結合してファイルパスを作成する
        $targetFilePath = Join-Path -Path $documentRootDirectoryPath -ChildPath $request.Url.AbsolutePath.TrimStart('/')
        if (-Not (Test-Path $targetFilePath)) {
            $response.StatusCode = 404
            $response.Close()
            continue
        }

        $rootUnit = Read-UnitFromFile -filePath $targetFilePath

        # 入れ子構造のユニット情報をul, li, details, summaryを用いたHTML形式でレスポンスとして返す
        function Convert-UnitToHtml {
            param (
                [hashtable]$unit
            )
            
            $html = "<li><details open><summary class='$($unit.UnitType)'>$($unit.Name):$($unit.Comment)</summary><ul>`n"
            foreach ($nestedUnit in $unit.NestedUnits) {
                $html += Convert-UnitToHtml -unit $nestedUnit
            }
            $html += "</ul></details></li>`n"
            return $html
        }

        Send-Response -filename "unitinfo.html" -htmlContent (Convert-UnitToHtml -unit $rootUnit) -response $response

    }
    elseif ($request.HttpMethod -eq "GET" -and $request.Url.AbsolutePath -eq "/end") {
        $response.StatusCode = 200
        $response.Close()
        break

    }
    elseif ($request.HttpMethod -eq "POST") {
        # ドキュメントルートディレクトリパスとリクエストされたファイル名を結合してファイルパスを作成する
        $targetFilePath = Join-Path -Path $documentRootDirectoryPath -ChildPath $request.Url.AbsolutePath.TrimStart('/')
        Write-Output $targetFilePath

        # ファイルパスの拡張子がajsでない、あるいはファイルが存在しない場合は、404を返す
        if (-Not ($targetFilePath -match '\.ajs$') -or -Not (Test-Path $targetFilePath)) {
            $response.StatusCode = 404
            $response.Close()
            continue
        }

        # リクエストパラメータにキーとして"split"が存在する場合は、ネストされたユニット情報を分割してファイルに書き出す
        if ($request.QueryString['action'] -eq 'split') {
            # $targetFilePathの拡張子を除いたファイル名のフォルダを作成する
            # すでに存在する場合は、フォルダ内のファイルをすべて削除する
            $folderPath = $targetFilePath -replace '\.ajs$'
            if (-Not (Test-Path $folderPath)) {
                New-Item -ItemType Directory -Path $folderPath > $null
            }
            else {
                Get-ChildItem -Path $folderPath | Remove-Item -Force
            }

            $targetUnitList = $rootUnit.NestedUnits

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
        }
        # リクエストパラメータにキーとして"merge"が存在する場合は、
        # ネストされたユニット情報を格納したフォルダからファイルを読み込み、親定義の該当ユニットを上書きし、ファイルに書き出す
        # 書き出す際のファイル名は、$targetFilePathの拡張子を除いた部分にタイムスタンプ(yyyyMMddHHmmss)を付加したものとする
        elseif ($request.QueryString['action'] -eq 'merge') {
            $folderPath = $targetFilePath -replace '\.ajs$'
            if (-Not (Test-Path $folderPath)) {
                $response.StatusCode = 404
                $response.Close()
                continue
            }

            $targetUnitList = $rootUnit.NestedUnits

            # $folderPath内のajsファイルをすべて読み込み、Read-UnitFromFileを用いてユニット情報を取得し、
            # $targetUnitListの要素のNameと一致するユニット情報を上書きする
            foreach ($filePath in (Get-ChildItem -Path $folderPath -Filter "*.ajs").FullName) {
                $nestUnit = Read-UnitFromFile -filePath $filePath

                for ($i = 0; $i -lt $targetUnitList.Count; $i++) {
                    if ($targetUnitList[$i].Name -eq $nestUnit.Name) {
                        $targetUnitList[$i] = $nestUnit
                        break
                    }
                }              
            }

            # $targetFilePathの拡張子を除いた部分にタイムスタンプ(yyyyMMddHHmmss)を付加したファイルに書き出す
            $timestamp = Get-Date -Format "yyyyMMddHHmmss"
            $outFilePath = $targetFilePath -replace '\.ajs$', "_$timestamp.ajs"
            $writer = [System.IO.StreamWriter]::new($outFilePath, $false, [System.Text.Encoding]::GetEncoding("Shift_JIS"))
            Write-UnitToFile -unit $rootUnit -depth 0 -writer $writer
            $writer.Close()

            $response.StatusCode = 200
            $response.Close()
        } else {
            $response.StatusCode = 404
            $response.Close()
        }
    }
    else {
        $response.StatusCode = 404
        $response.Close()
    }
}
$listener.Stop()