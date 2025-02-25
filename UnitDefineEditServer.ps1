# �����Ƀh�L�������g���[�g�f�B���N�g���p�X���󂯎��
param (
    [Parameter(Mandatory=$true)][string]$documentRootDirectoryPath
)

# �f�B���N�g���p�X�Ƀf�B���N�g�������݂��邩�`�F�b�N����
if (-Not (Test-Path $documentRootDirectoryPath)) {
    Write-Error "The specified directory $documentRootDirectoryPath does not exist."
    exit 1
}

$rootUnit = $null

# HTTP�T�[�o�[���쐬����
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
        # ����q�\���̃f�B���N�g��, ajs�t�@�C����ul, li, details, summary��p����HTML�`���Ń��X�|���X�Ƃ��ĕԂ�
        function Convert-DirectoryToHtml {
            param ([string]$directoryPath)
            # �f�B���N�g���̍ċA�I�ȉ��ʂ�ajs�t�@�C����1�����݂��Ȃ��ꍇ�́A��̕������Ԃ�
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
        # �h�L�������g���[�g�f�B���N�g���p�X�ƃ��N�G�X�g���ꂽ�t�@�C�������������ăt�@�C���p�X���쐬����
        $targetFilePath = Join-Path -Path $documentRootDirectoryPath -ChildPath $request.Url.AbsolutePath.TrimStart('/')
        if (-Not (Test-Path $targetFilePath)) {
            $response.StatusCode = 404
            $response.Close()
            continue
        }
        $response.ContentType = 'text/html; charset=Shift_JIS'
        $response.StatusCode = 200

        # SJIS�ō쐬���ꂽ1�ڂ̃t�@�C����1�s���ǂݍ��݁A����q�\���̃��j�b�g�����擾����
        # - "unit="�Ŏn�܂�s�́A���s����n�܂�{ ... }�Z�N�V�����̃T�}���ł���A�J���}��؂�ł���E�ӂ�1���ږڂ����j�b�g��
        #  - �� unit=GA,,jp1usr01,;
        # - { ... }�Z�N�V��������"cm="�Ŏn�܂�s�����j�b�g�̃R�����g
        #  - �� 	cm="�Œ莑�Y�Łi�y�n�E�Ɖ��j";
        # - { ... }�Z�N�V��������"unit="�Ŏn�܂�s������ꍇ�A���s����l�X�g���ꂽ{ ... }�Z�N�V�������n�܂�
        # - { ... }�Z�N�V�������̓^�u�ŃC���f���g����A�l�X�g�����̃^�u���擪�ɕt�������
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

        # ����q�\���̃��j�b�g����ul, li, details, summary��p����HTML�`���Ń��X�|���X�Ƃ��ĕԂ�
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
        # �h�L�������g���[�g�f�B���N�g���p�X�ƃ��N�G�X�g���ꂽ�t�@�C�������������ăt�@�C���p�X���쐬����
        $targetFilePath = Join-Path -Path $documentRootDirectoryPath -ChildPath $request.Url.AbsolutePath.TrimStart('/')
        Write-Output $targetFilePath

        # �t�@�C���p�X�̊g���q��ajs�łȂ��A���邢�̓t�@�C�������݂��Ȃ��ꍇ�́A404��Ԃ�
        if (-Not ($targetFilePath -match '\.ajs$') -or -Not (Test-Path $targetFilePath)) {
            $response.StatusCode = 404
            $response.Close()
            continue
        }

        # $filePath1�̊g���q���������t�@�C�����̃t�H���_���쐬����
        # ���łɑ��݂���ꍇ�́A�t�H���_���̃t�@�C�������ׂč폜����
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

        # $targetUnitList�̗v�f��Name+".ajs"���A��ō쐬�����t�H���_�ɍ쐬���A
        # Write-UnitToFile��p���ă��j�b�g���������o��
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