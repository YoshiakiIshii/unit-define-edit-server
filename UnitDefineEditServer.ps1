# �����Ƀh�L�������g���[�g�f�B���N�g���p�X���󂯎��
param (
    [Parameter(Mandatory = $true)][string]$documentRootDirectoryPath
)

# SJIS�ō쐬���ꂽ1�ڂ̃t�@�C����1�s���ǂݍ��݁A����q�\���̃��j�b�g�����擾����
# - "unit="�Ŏn�܂�s�́A���s����n�܂�{ ... }�Z�N�V�����̃T�}���ł���A�J���}��؂�ł���E�ӂ�1���ږڂ����j�b�g��
#  - �� unit=GA,,jp1usr01,;
# - { ... }�Z�N�V��������"cm="�Ŏn�܂�s�����j�b�g�̃R�����g
#  - �� 	cm="�Œ莑�Y�Łi�y�n�E�Ɖ��j";
# - { ... }�Z�N�V��������"ty="�Ŏn�܂�s�����j�b�g��ʒ�`
# - { ... }�Z�N�V��������"unit="�Ŏn�܂�s������ꍇ�A���s����l�X�g���ꂽ{ ... }�Z�N�V�������n�܂�
# - { ... }�Z�N�V�������̓^�u�ŃC���f���g����A�l�X�g�����̃^�u���擪�ɕt�������
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
        # �h�L�������g���[�g�f�B���N�g���p�X�ƃ��N�G�X�g���ꂽ�t�@�C�������������ăt�@�C���p�X���쐬����
        $targetFilePath = Join-Path -Path $documentRootDirectoryPath -ChildPath $request.Url.AbsolutePath.TrimStart('/')
        if (-Not (Test-Path $targetFilePath)) {
            $response.StatusCode = 404
            $response.Close()
            continue
        }

        $rootUnit = Read-UnitFromFile -filePath $targetFilePath

        # ����q�\���̃��j�b�g����ul, li, details, summary��p����HTML�`���Ń��X�|���X�Ƃ��ĕԂ�
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
        # �h�L�������g���[�g�f�B���N�g���p�X�ƃ��N�G�X�g���ꂽ�t�@�C�������������ăt�@�C���p�X���쐬����
        $targetFilePath = Join-Path -Path $documentRootDirectoryPath -ChildPath $request.Url.AbsolutePath.TrimStart('/')
        Write-Output $targetFilePath

        # �t�@�C���p�X�̊g���q��ajs�łȂ��A���邢�̓t�@�C�������݂��Ȃ��ꍇ�́A404��Ԃ�
        if (-Not ($targetFilePath -match '\.ajs$') -or -Not (Test-Path $targetFilePath)) {
            $response.StatusCode = 404
            $response.Close()
            continue
        }

        # ���N�G�X�g�p�����[�^�ɃL�[�Ƃ���"split"�����݂���ꍇ�́A�l�X�g���ꂽ���j�b�g���𕪊����ăt�@�C���ɏ����o��
        if ($request.QueryString['action'] -eq 'split') {
            # $targetFilePath�̊g���q���������t�@�C�����̃t�H���_���쐬����
            # ���łɑ��݂���ꍇ�́A�t�H���_���̃t�@�C�������ׂč폜����
            $folderPath = $targetFilePath -replace '\.ajs$'
            if (-Not (Test-Path $folderPath)) {
                New-Item -ItemType Directory -Path $folderPath > $null
            }
            else {
                Get-ChildItem -Path $folderPath | Remove-Item -Force
            }

            $targetUnitList = $rootUnit.NestedUnits

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
        }
        # ���N�G�X�g�p�����[�^�ɃL�[�Ƃ���"merge"�����݂���ꍇ�́A
        # �l�X�g���ꂽ���j�b�g�����i�[�����t�H���_����t�@�C����ǂݍ��݁A�e��`�̊Y�����j�b�g���㏑�����A�t�@�C���ɏ����o��
        # �����o���ۂ̃t�@�C�����́A$targetFilePath�̊g���q�������������Ƀ^�C���X�^���v(yyyyMMddHHmmss)��t���������̂Ƃ���
        elseif ($request.QueryString['action'] -eq 'merge') {
            $folderPath = $targetFilePath -replace '\.ajs$'
            if (-Not (Test-Path $folderPath)) {
                $response.StatusCode = 404
                $response.Close()
                continue
            }

            $targetUnitList = $rootUnit.NestedUnits

            # $folderPath����ajs�t�@�C�������ׂēǂݍ��݁ARead-UnitFromFile��p���ă��j�b�g�����擾���A
            # $targetUnitList�̗v�f��Name�ƈ�v���郆�j�b�g�����㏑������
            foreach ($filePath in (Get-ChildItem -Path $folderPath -Filter "*.ajs").FullName) {
                $nestUnit = Read-UnitFromFile -filePath $filePath

                for ($i = 0; $i -lt $targetUnitList.Count; $i++) {
                    if ($targetUnitList[$i].Name -eq $nestUnit.Name) {
                        $targetUnitList[$i] = $nestUnit
                        break
                    }
                }              
            }

            # $targetFilePath�̊g���q�������������Ƀ^�C���X�^���v(yyyyMMddHHmmss)��t�������t�@�C���ɏ����o��
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