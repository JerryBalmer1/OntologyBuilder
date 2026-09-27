#Requires -Version 7.4
Param(
)

Register-ArgumentCompleter -CommandName Invoke-Build.ps1 -ParameterName Task -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $boundParameters)

    (Invoke-Build -Task ?? -File ($boundParameters['File'])).get_Keys() -like "$wordToComplete*" | .{process{
        New-Object System.Management.Automation.CompletionResult $_, $_, 'ParameterValue', $_
    }}
}

Register-ArgumentCompleter -CommandName Invoke-Build.ps1 -ParameterName File -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $boundParameters)

    Get-ChildItem -Directory -Name "$wordToComplete*" | .{process{
        New-Object System.Management.Automation.CompletionResult $_, $_, 'ProviderContainer', $_
    }}

    if (!($boundParameters['Task'] -eq '**')) {
        Get-ChildItem -File -Name "$wordToComplete*.ps1" | .{process{
            New-Object System.Management.Automation.CompletionResult $_, $_, 'Command', $_
        }}
    }
}

task TerraformInit {

    try {

        push-location sources/terraform

        terraform init

    }
    catch {
        Write-Error $_
    }
    finally {
        if ((Get-Location).Path -like "*sources/terraform*") {
            pop-location
        }
    }
}

task TerraformScript {

    try {

        push-location sources/terraform

        .\terraform.schema.build.ps1

    }
    catch {
        Write-Error $_
    }
    finally {
        if ((Get-Location).Path -like "*sources/terraform*") {
            pop-location
        }
    }

}

task . TerraformScript