# ������2�̃t�@�C���p�X(�g���q��.ajs)���󂯎��AWeb�T�[�o�[���쐬����1�ڂ̃t�@�C�������̂܂܃��X�|���X�Ƃ��ĕԂ��T�[�o�[���쐬����
param (
    [Parameter(Mandatory=$true)]
    [string]$filePath1,

    [Parameter(Mandatory=$true)]
    [string]$filePath2
)

# 1�ڂ̃t�@�C���p�X�Ƀt�@�C�������݂��邩�`�F�b�N����(2�ڂ͑��݂��Ȃ��Ă悢)
if (-Not (Test-Path $filePath1)) {
    Write-Error "The specified file $filePath1 does not exist."
    exit 1
}

$rootUnit = $null

# �V���v����HTTP�T�[�o�[���쐬����
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

        # ����q�\���̃��j�b�g����ul, li, details, summary��p����HTML�`���Ń��X�|���X�Ƃ��ĕԂ�
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

        # $rootUnit��NestedUnits���ċA�I�ɒH��Ȃ���AName��Comment���t�H�[�}�b�g����$filePath2�ɒ��������o��
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