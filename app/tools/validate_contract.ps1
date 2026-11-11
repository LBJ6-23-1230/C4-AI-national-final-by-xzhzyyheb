param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$contractPath = Join-Path $ProjectRoot 'contracts\openapi.json'
$fixtureRoot = Join-Path $ProjectRoot 'contracts\fixtures'

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing JSON file: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$contract = Read-JsonFile $contractPath
Assert-Equal $contract.openapi '3.0.3' 'Unexpected OpenAPI version.'
Assert-Equal $contract.info.version 'api-contract-v0.3' 'Unexpected API contract version.'

$requiredPaths = @(
    '/',
    '/api/agent/chat',
    '/api/agent/health',
    '/api/agent/history',
    '/api/agent/user-data',
    '/api/v1/agent/partner-match',
    '/api/v1/experiments/snapshot',
    '/api/v1/agent/proactive',
    '/api/v1/auth/account',
    '/api/v1/auth/change-password',
    '/api/v1/auth/login',
    '/api/v1/auth/login-or-register',
    '/api/v1/auth/login-with-huawei',
    '/api/v1/auth/logout',
    '/api/v1/auth/me',
    '/api/v1/auth/register',
    '/api/v1/auth/send-code',
    '/api/v1/auth/verify-code',
    '/api/v1/demo/reset',
    '/api/v1/documents/{documentId}',
    '/api/v1/exercises/{exerciseId}/sources',
    '/api/v1/exercises/{setId}',
    '/api/v1/exercises/{setId}/submit',
    '/api/v1/focus-sessions',
    '/api/v1/import/schedule-image',
    '/api/v1/knowledge-bases',
    '/api/v1/knowledge-bases/{kbId}',
    '/api/v1/knowledge-bases/{kbId}/documents',
    '/api/v1/knowledge-bases/{kbId}/search',
    '/api/v1/plans/{id}/diff',
    '/api/v1/plans/current',
    '/api/v1/plans/current/availability',
    '/api/v1/profile/{user_id}/knowledge-points',
    '/api/v1/profile/{userId}',
    '/api/v1/traces/{traceId}',
    '/api/v1/workflows',
    '/api/v1/workflows/{id}',
    '/api/v1/workflows/{id}/run',
    '/api/v1/workflows/chat/{chatSessionId}',
    '/api/v1/wrong-book',
    '/api/v1/wrong-book/{exerciseId}',
    '/api/v1/wrong-book/{exerciseId}/attempt',
    '/health'
)
$actualPaths = @($contract.paths.PSObject.Properties.Name)
foreach ($path in $requiredPaths) {
    if ($actualPaths -notcontains $path) {
        throw "OpenAPI path missing: $path"
    }
}
$unexpectedPaths = @($actualPaths | Where-Object { $requiredPaths -notcontains $_ })
if ($unexpectedPaths.Count -gt 0) {
    throw "OpenAPI contains paths not covered by this validator: $($unexpectedPaths -join ', ')"
}
Assert-Equal $actualPaths.Count $requiredPaths.Count 'OpenAPI path coverage mismatch.'

$apiClientPath = Join-Path $ProjectRoot 'entry\src\main\ets\api\AgentApiClient.ets'
if (-not (Test-Path -LiteralPath $apiClientPath -PathType Leaf)) {
    throw "Missing frontend API client: $apiClientPath"
}
$apiClientSource = Get-Content -LiteralPath $apiClientPath -Raw -Encoding UTF8
$requiredClientMarkers = @(
    '/api/v1/agent/proactive',
    '/api/v1/workflows',
    '/api/v1/workflows/chat/',
    '/run',
    '/api/v1/profile/',
    '/knowledge-points',
    '/api/v1/plans/current',
    '/api/v1/exercises/',
    '/sources',
    '/submit',
    '/diff',
    '/api/v1/traces/',
    '/api/v1/demo/reset'
)
foreach ($clientMarker in $requiredClientMarkers) {
    if (-not $apiClientSource.Contains($clientMarker)) {
        throw "Frontend API client route missing: $clientMarker"
    }
}

$mainPagesPath = Join-Path $ProjectRoot 'entry\src\main\resources\base\profile\main_pages.json'
$mainPages = Read-JsonFile $mainPagesPath
$allowedCardTargets = @(
    'pages/Index',
    'pages/StudySuggestion',
    'pages/WrongQuestion',
    'pages/StudyTags',
    'pages/CourseImport',
    'pages/ExercisePractice',
    'pages/AgentTrace',
    'pages/PartnerMatch',
    'pages/StudyPlan',
    'pages/ReviewSummary',
    'pages/FocusSetup'
)
foreach ($targetPage in $allowedCardTargets) {
    if ($mainPages.src -notcontains $targetPage) {
        throw "Chat card target is not registered in main_pages.json: $targetPage"
    }
}

$etsRoot = Join-Path $ProjectRoot 'entry\src\main\ets'
$navigationTargets = @(
    Get-ChildItem -LiteralPath $etsRoot -Recurse -Filter '*.ets' -File |
        Select-String -Pattern '(?<route>pages/[A-Za-z0-9_]+)' -AllMatches |
        ForEach-Object { $_.Matches } |
        ForEach-Object { $_.Groups['route'].Value } |
        Sort-Object -Unique
)
foreach ($navigationTarget in $navigationTargets) {
    if ($mainPages.src -notcontains $navigationTarget) {
        throw "ArkTS navigation target is not registered in main_pages.json: $navigationTarget"
    }
}

$fixtureNames = @(
    'chat-response.json',
    'workflow-created.json',
    'workflow-running.json',
    'workflow-completed.json',
    'profile-v1.json',
    'profile-v2.json',
    'plan-v1.json',
    'plan-v2.json',
    'exercise-set.json',
    'exercise-submission-result.json',
    'plan-diff.json',
    'trace-before.json',
    'trace-after.json',
    'demo-reset.json'
)
$fixtures = @{}
foreach ($name in $fixtureNames) {
    $fixtures[$name] = Read-JsonFile (Join-Path $fixtureRoot $name)
}

Assert-Equal $fixtures['profile-v1.json'].profileVersion 1 'Initial profile version mismatch.'
Assert-Equal $fixtures['profile-v1.json'].mastery[0].masteryScore 42 'Initial mastery mismatch.'
Assert-Equal $fixtures['profile-v2.json'].profileVersion 2 'Updated profile version mismatch.'
Assert-Equal $fixtures['profile-v2.json'].mastery[0].masteryScore 58 'Updated mastery mismatch.'
Assert-Equal $fixtures['plan-v1.json'].version 1 'Initial plan version mismatch.'
Assert-Equal $fixtures['plan-v1.json'].tasks[0].durationMinutes 30 'Initial plan duration mismatch.'
Assert-Equal $fixtures['plan-v2.json'].version 2 'Updated plan version mismatch.'
Assert-Equal $fixtures['plan-v2.json'].tasks[0].durationMinutes 45 'Updated plan duration mismatch.'
Assert-Equal $fixtures['exercise-set.json'].exercises.Count 3 'Exercise count mismatch.'
Assert-Equal $fixtures['exercise-submission-result.json'].assessment.score 67 'Assessment score mismatch.'
Assert-Equal $fixtures['exercise-submission-result.json'].masteryUpdate.oldScore 42 'Assessment old mastery mismatch.'
Assert-Equal $fixtures['exercise-submission-result.json'].masteryUpdate.newScore 58 'Assessment new mastery mismatch.'
Assert-Equal $fixtures['plan-diff.json'].oldVersion 1 'Plan diff old version mismatch.'
Assert-Equal $fixtures['plan-diff.json'].newVersion 2 'Plan diff new version mismatch.'
Assert-Equal $fixtures['trace-after.json'].events.Count 5 'Completed trace length mismatch.'
Assert-Equal $fixtures['workflow-completed.json'].stateVersion 5 'Completed workflow state version mismatch.'
Assert-Equal $fixtures['demo-reset.json'].profile.profileVersion 1 'Reset profile version mismatch.'
Assert-Equal $fixtures['demo-reset.json'].plan.version 1 'Reset plan version mismatch.'

$jsonCount = @(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.json' -File).Count
Write-Output "Contract valid: $($requiredPaths.Count) paths fully covered; $($requiredClientMarkers.Count) frontend route markers; $jsonCount fixture files; $($navigationTargets.Count) registered navigation targets; api-contract-v0.3 declared surface is consistent."
