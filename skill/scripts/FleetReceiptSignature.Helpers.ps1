# Dot-sourceable HMAC-SHA256 Fleet receipt signatures (schema v2 TLV).
# NO top-level side effects. Design: .fleet/sr-design.md sections 1 and 3.
# Public: New-FleetReceiptSignature, Test-FleetReceiptSignature.

$script:FrsUtf8 = New-Object System.Text.UTF8Encoding $false
$script:FrsShaRe = '^[0-9a-f]{64}$'
$script:FrsKeyIdRe = '^[0-9a-f]{32}$'
$script:FrsTsRe = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
$script:FrsSigRe = '^[0-9a-f]{64}$'
# domain = UTF8("fleet-receipt-hmac") 0x00 UTF8("v2") 0x00
$script:FrsDom = [byte[]](0x66,0x6c,0x65,0x65,0x74,0x2d,0x72,0x65,0x63,0x65,0x69,0x70,0x74,0x2d,0x68,0x6d,0x61,0x63,0x00,0x76,0x32,0x00)
# kinds: c const, id ident, s string, role, sha, kid, ts, i int64, b bool, ns null|str, sa str[], fa finding[], sig excl
$script:FrsRL = @(
  @{n='schema_version';k='c';v='2'},@{n='receipt_type';k='c';v='review_lane'},
  @{n='run_id';k='id'},@{n='task_id';k='id'},@{n='lane_id';k='id'},@{n='voice_id';k='id'},@{n='review_role';k='role'},
  @{n='requested_model';k='s'},@{n='observed_model';k='s'},@{n='model_evidence';k='s'},@{n='emitter_id';k='id'},
  @{n='input_packet_sha256';k='sha'},@{n='expected_lane_manifest_sha256';k='sha'},@{n='locked_plan_sha256';k='sha'},
  @{n='review_profile';k='s'},@{n='charter_path';k='s'},@{n='review_tier';k='s'},@{n='result_path';k='s'},
  @{n='charter_sha256';k='sha'},@{n='result_sha256';k='sha'},@{n='exit_code';k='i'},@{n='outcome';k='s'},
  @{n='refusal_reason';k='ns'},@{n='fallback_of';k='ns'},@{n='started_at';k='ts'},@{n='completed_at';k='ts'},
  @{n='sig_alg';k='c';v='HMAC-SHA256'},@{n='key_id';k='kid'},@{n='signature';k='sig'}
)
$script:FrsMS = @(
  @{n='schema_version';k='c';v='2'},@{n='receipt_type';k='c';v='merge_stage'},
  @{n='run_id';k='id'},@{n='task_id';k='id'},@{n='lane_id';k='id'},@{n='stage';k='s'},@{n='required';k='b'},
  @{n='status';k='s'},@{n='requested_model';k='s'},@{n='observed_model';k='s'},@{n='model_evidence';k='s'},
  @{n='effort';k='s'},@{n='input_packet_sha256';k='sha'},@{n='emitter_id';k='id'},@{n='locked_plan_sha256';k='sha'},
  @{n='stage_set_sha256';k='sha'},@{n='review_tier';k='s'},@{n='review_profile';k='s'},@{n='charter_path';k='s'},
  @{n='result_path';k='s'},@{n='result_sha256';k='sha'},@{n='charter_sha256';k='sha'},@{n='exit_code';k='i'},
  @{n='outcome';k='s'},@{n='fallback_of';k='ns'},@{n='failure_category';k='ns'},@{n='findings';k='fa'},
  @{n='evidence_refs';k='sa'},@{n='output_artifacts';k='sa'},@{n='started_at';k='ts'},@{n='completed_at';k='ts'},
  @{n='model';k='s'},@{n='sig_alg';k='c';v='HMAC-SHA256'},@{n='signature';k='sig'}
)

function Get-FrsSchema([string]$t) {
  if ($t -ceq 'review_lane') { $script:FrsRL; return }
  if ($t -ceq 'merge_stage') { $script:FrsMS; return }
  $null
}
function Get-FrsNames($o) { @($o.PSObject.Properties | ForEach-Object { $_.Name }) }
function Test-FrsNames([string[]]$h, [string[]]$w) {
  if ($h.Count -ne $w.Count) { return $false }
  for ($i = 0; $i -lt $w.Count; $i++) { if ($h[$i] -cne $w[$i]) { return $false } }
  $true
}
function Test-FrsInt($v) {
  if ($null -eq $v -or $v -is [bool] -or $v -is [string]) { return $false }
  if ($v -is [byte] -or $v -is [sbyte] -or $v -is [int16] -or $v -is [uint16] -or $v -is [int32] -or $v -is [uint32] -or $v -is [int64] -or $v -is [long] -or $v -is [int]) { return $true }
  if ($v -is [double] -or $v -is [float] -or $v -is [single] -or $v -is [decimal]) {
    $d = [double]$v
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $false }
    return ($d -eq [math]::Floor($d) -and $d -ge [int64]::MinValue -and $d -le [int64]::MaxValue)
  }
  $false
}
function Test-FrsId([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return $false }
  -not ([char]::IsWhiteSpace($s, 0) -or [char]::IsWhiteSpace($s, $s.Length - 1))
}
function Write-FrsU16([IO.MemoryStream]$ms, [uint16]$v) {
  $ms.WriteByte([byte](($v -shr 8) -band 0xFF)); $ms.WriteByte([byte]($v -band 0xFF))
}
function Write-FrsU32([IO.MemoryStream]$ms, [uint32]$v) {
  $ms.WriteByte([byte](($v -shr 24) -band 0xFF)); $ms.WriteByte([byte](($v -shr 16) -band 0xFF))
  $ms.WriteByte([byte](($v -shr 8) -band 0xFF)); $ms.WriteByte([byte]($v -band 0xFF))
}
function Write-FrsRaw([IO.MemoryStream]$ms, [byte[]]$b) {
  if ($null -ne $b -and $b.Length -gt 0) { $ms.Write($b, 0, $b.Length) }
}
function Get-FrsI64BE([int64]$n) {
  $b = [BitConverter]::GetBytes($n)
  if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($b) }
  ,$b
}
function Write-FrsTV([IO.MemoryStream]$ms, [byte]$tag, [byte[]]$val) {
  # Field value = type_tag || uint32_be(len) || bytes. Null (tag 0x00) and empty string
  # (tag 0x01, len 0) share len=0 but MUST differ by tag so HMACs diverge.
  $ms.WriteByte($tag)
  if ($null -eq $val) {
    Write-FrsU32 $ms 0
  } else {
    Write-FrsU32 $ms ([uint32]$val.Length)
    Write-FrsRaw $ms $val
  }
}
function Write-FrsField([IO.MemoryStream]$ms, [string]$name, [byte]$tag, [byte[]]$val) {
  $nb = $script:FrsUtf8.GetBytes($name)
  if ($nb.Length -gt 65535) { throw 'field name too long' }
  Write-FrsU16 $ms ([uint16]$nb.Length); Write-FrsRaw $ms $nb; Write-FrsTV $ms $tag $val
}
function Get-FrsStr([string]$s) {
  # Always return a real byte[] (possibly length 0). Never $null — null TLV is tag 0x00 only.
  $b = $script:FrsUtf8.GetBytes($s)
  if ($null -eq $b) { $b = New-Object byte[] 0 }
  ,$b
}
function Get-FrsFinding($f) {
  if ($null -eq $f -or $f -is [string] -or $f -is [bool] -or $f -is [ValueType]) { throw 'finding not object' }
  if (-not (Test-FrsNames (Get-FrsNames $f) @('severity','id','resolved'))) { throw 'finding fields' }
  if (-not ($f.severity -is [string] -and $f.id -is [string] -and $f.resolved -is [bool])) { throw 'finding types' }
  $inner = New-Object IO.MemoryStream
  try {
    Write-FrsField $inner 'severity' 0x01 (Get-FrsStr ([string]$f.severity))
    Write-FrsField $inner 'id' 0x01 (Get-FrsStr ([string]$f.id))
    $rt = 0x03; if ([bool]$f.resolved) { $rt = 0x04 }
    Write-FrsField $inner 'resolved' $rt $null
    ,$inner.ToArray()
  } finally { $inner.Dispose() }
}
function Get-FrsArr($arr, [string]$ek) {
  if ($null -eq $arr -or -not ($arr -is [System.Array])) { throw 'not array' }
  $body = New-Object IO.MemoryStream
  try {
    $items = @($arr); Write-FrsU32 $body ([uint32]$items.Count)
    foreach ($el in $items) {
      if ($ek -eq 's') {
        if (-not ($el -is [string])) { throw 'arr elem' }
        Write-FrsTV $body 0x01 (Get-FrsStr ([string]$el))
      } elseif ($ek -eq 'f') { Write-FrsTV $body 0x06 (Get-FrsFinding $el) }
      else { throw 'elem kind' }
    }
    ,$body.ToArray()
  } finally { $body.Dispose() }
}
function Get-FrsPayload($val, [string]$k, $spec) {
  switch ($k) {
    'c' {
      if (-not ($val -is [string]) -or ([string]$val) -cne [string]$spec.v) { throw 'const' }
      @{ t = [byte]0x01; b = (Get-FrsStr ([string]$val)) }
    }
    'id' {
      if (-not ($val -is [string]) -or -not (Test-FrsId ([string]$val))) { throw 'id' }
      @{ t = [byte]0x01; b = (Get-FrsStr ([string]$val)) }
    }
    's' {
      if (-not ($val -is [string]) -or -not (Test-FrsId ([string]$val))) { throw 'str' }
      @{ t = [byte]0x01; b = (Get-FrsStr ([string]$val)) }
    }
    'role' {
      $s = [string]$val
      if (-not ($val -is [string]) -or ($s -cne 'general-review' -and $s -cne 'security-review')) { throw 'role' }
      @{ t = [byte]0x01; b = (Get-FrsStr $s) }
    }
    'sha' {
      if (-not ($val -is [string]) -or ([string]$val) -cnotmatch $script:FrsShaRe) { throw 'sha' }
      @{ t = [byte]0x01; b = (Get-FrsStr ([string]$val)) }
    }
    'kid' {
      if (-not ($val -is [string]) -or ([string]$val) -cnotmatch $script:FrsKeyIdRe) { throw 'kid' }
      @{ t = [byte]0x01; b = (Get-FrsStr ([string]$val)) }
    }
    'ts' {
      if (-not ($val -is [string]) -or ([string]$val) -cnotmatch $script:FrsTsRe) { throw 'ts' }
      @{ t = [byte]0x01; b = (Get-FrsStr ([string]$val)) }
    }
    'i' {
      if (-not (Test-FrsInt $val)) { throw 'int' }
      @{ t = [byte]0x02; b = (Get-FrsI64BE ([int64]$val)) }
    }
    'b' {
      if (-not ($val -is [bool])) { throw 'bool' }
      $t = 0x03; if ([bool]$val) { $t = 0x04 }
      @{ t = [byte]$t; b = $null }
    }
    'ns' {
      # null → tag 0x00 + uint32_be(0); empty string → tag 0x01 + uint32_be(0). Tags MUST differ.
      if ($null -eq $val) { return @{ t = [byte]0x00; b = $null } }
      if (-not ($val -is [string])) { throw 'ns' }
      # Do not cast through paths that collapse $null↔"". Empty string stays tag 0x01.
      if ($val.Length -gt 0 -and -not (Test-FrsId $val)) { throw 'ns pad' }
      if ($val.Length -eq 0) {
        return @{ t = [byte]0x01; b = (New-Object byte[] 0) }
      }
      @{ t = [byte]0x01; b = (Get-FrsStr $val) }
    }
    'sa' { @{ t = [byte]0x05; b = (Get-FrsArr $val 's') } }
    'fa' { @{ t = [byte]0x05; b = (Get-FrsArr $val 'f') } }
    default { throw 'kind' }
  }
}
function Get-FrsCanon($Receipt, $Schema, [string]$RType) {
  $ms = New-Object IO.MemoryStream
  try {
    Write-FrsRaw $ms $script:FrsDom
    Write-FrsRaw $ms ($script:FrsUtf8.GetBytes($RType)); $ms.WriteByte(0x00)
    foreach ($spec in $Schema) {
      if ($spec.k -eq 'sig') { continue }
      $p = Get-FrsPayload $Receipt.($spec.n) $spec.k $spec
      Write-FrsField $ms ([string]$spec.n) $p.t $p.b
    }
    ,$ms.ToArray()
  } finally { $ms.Dispose() }
}
function Get-FrsHmac([byte[]]$Key, [byte[]]$Msg) {
  $h = New-Object Security.Cryptography.HMACSHA256
  try {
    $h.Key = $Key; $hash = $h.ComputeHash($Msg)
    $sb = New-Object Text.StringBuilder ($hash.Length * 2)
    foreach ($x in $hash) { [void]$sb.Append($x.ToString('x2')) }
    $sb.ToString()
  } finally { $h.Dispose() }
}
function Get-FrsHex32([string]$hex) {
  $out = New-Object byte[] 32
  for ($i = 0; $i -lt 32; $i++) { $out[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
  ,$out
}
function Test-FrsCtEq([byte[]]$a, [byte[]]$b) {
  if ($null -eq $a -or $null -eq $b -or $a.Length -ne 32 -or $b.Length -ne 32) { return $false }
  $d = 0; for ($i = 0; $i -lt 32; $i++) { $d = $d -bor ($a[$i] -bxor $b[$i]) }
  $d -eq 0
}
function Assert-FrsKey([byte[]]$s, [string]$kid) {
  if ($null -eq $s -or $s.Length -ne 32) { throw 'secret' }
  if ($kid -cnotmatch $script:FrsKeyIdRe) { throw 'key_id' }
}
function Resolve-FrsShape($Receipt, $Schema) {
  $have = Get-FrsNames $Receipt
  $signed = @($Schema | Where-Object { $_.k -ne 'sig' } | ForEach-Object { $_.n })
  $full = @($Schema | ForEach-Object { $_.n })
  if (Test-FrsNames $have $signed) { return @{ ok = $true } }
  if (Test-FrsNames $have $full) { return @{ ok = $true } }
  @{ ok = $false }
}
function Assert-FrsTypes($Receipt, $Schema, [string]$RType, [string]$KeyId) {
  foreach ($spec in $Schema) {
    if ($spec.k -eq 'sig') { continue }
    $null = Get-FrsPayload $Receipt.($spec.n) $spec.k $spec
  }
  if ([string]$Receipt.receipt_type -cne $RType) { throw 'rtype' }
  if ($RType -ceq 'merge_stage' -and ([string]$Receipt.model) -cne ([string]$Receipt.requested_model)) { throw 'model' }
  foreach ($spec in $Schema) {
    if ($spec.n -ceq 'key_id' -and ([string]$Receipt.key_id) -cne $KeyId) { throw 'kid mismatch' }
  }
}
function New-FrsRes([bool]$ok, [string]$reason) { [pscustomobject]@{ ok = $ok; reason = $reason } }

function New-FleetReceiptSignature {
  param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$ReceiptType,
    [Parameter(Mandatory)][byte[]]$RunSecret, [Parameter(Mandatory)][string]$KeyId)
  Assert-FrsKey $RunSecret $KeyId
  $schema = @(Get-FrsSchema $ReceiptType)
  if ($schema.Count -lt 2) { throw 'unsupported receipt_type' }
  if ($null -eq $Receipt) { throw 'receipt null' }
  if (-not (Resolve-FrsShape $Receipt $schema).ok) { throw 'noncanonical property list' }
  Assert-FrsTypes $Receipt $schema $ReceiptType $KeyId
  Get-FrsHmac $RunSecret (Get-FrsCanon $Receipt $schema $ReceiptType)
}

function Test-FleetReceiptSignature {
  param([Parameter(Mandatory)]$Receipt, [Parameter(Mandatory)][string]$ReceiptType,
    [Parameter(Mandatory)][byte[]]$RunSecret, [Parameter(Mandatory)][string]$KeyId,
    [AllowNull()][string]$Signature)
  if ($null -eq $Signature -or [string]::IsNullOrEmpty([string]$Signature)) { return (New-FrsRes $false 'missing_signature') }
  try { Assert-FrsKey $RunSecret $KeyId } catch { return (New-FrsRes $false 'noncanonical_shape') }
  $schema = @(Get-FrsSchema $ReceiptType)
  if ($schema.Count -lt 2 -or $null -eq $Receipt) { return (New-FrsRes $false 'noncanonical_shape') }
  if (-not (Resolve-FrsShape $Receipt $schema).ok) { return (New-FrsRes $false 'noncanonical_shape') }
  $sv = $Receipt.schema_version
  if ($null -ne $sv -and (-not ($sv -is [string]) -or ([string]$sv) -cne '2')) { return (New-FrsRes $false 'unsupported_schema') }
  $alg = $Receipt.sig_alg
  if ($null -ne $alg -and (-not ($alg -is [string]) -or ([string]$alg) -cne 'HMAC-SHA256')) { return (New-FrsRes $false 'unsupported_algorithm') }
  $hasKid = $false
  foreach ($spec in $schema) { if ($spec.n -ceq 'key_id') { $hasKid = $true; break } }
  if ($hasKid) {
    $kid = $Receipt.key_id
    if ($null -eq $kid -or -not ($kid -is [string]) -or ([string]$kid) -cne $KeyId) { return (New-FrsRes $false 'wrong_key_id') }
  }
  try {
    Assert-FrsTypes $Receipt $schema $ReceiptType $KeyId
    $bytes = Get-FrsCanon $Receipt $schema $ReceiptType
  } catch { return (New-FrsRes $false 'noncanonical_shape') }
  $sig = [string]$Signature
  if ($sig -cnotmatch $script:FrsSigRe) { return (New-FrsRes $false 'bad_signature') }
  if (-not (Test-FrsCtEq (Get-FrsHex32 $sig) (Get-FrsHex32 (Get-FrsHmac $RunSecret $bytes)))) {
    return (New-FrsRes $false 'bad_signature')
  }
  New-FrsRes $true 'ok'
}
