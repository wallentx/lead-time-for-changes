#!/usr/bin/env bash

# Function to display usage information
usage() {
    echo "Usage: $0 -o ownerRepo -w workflows -b branch -n numberOfDays -c commitCountingMethod [-p patToken] [-a actionsToken] [-i appId] [-I appInstallationId] [-k appPrivateKey] [-v]"
    echo ""
    echo "  -o  ownerRepo           The owner and repository in the format owner/repo"
    echo "  -w  workflows           Comma-separated list of workflow names"
    echo "  -b  branch              Branch name"
    echo "  -n  numberOfDays        Number of days to look back"
    echo "  -c  commitCountingMethod Commit counting method ('first' or 'last')"
    echo "  -p  patToken            Personal Access Token (optional)"
    echo "  -a  actionsToken        GitHub Actions Token (optional)"
    echo "  -i  appId               GitHub App ID (optional)"
    echo "  -I  appInstallationId   GitHub App Installation ID (optional)"
    echo "  -k  appPrivateKey       GitHub App Private Key (optional)"
    echo "  -v                      Enable debug (optional)"
    exit 1
}

# Main function
main() {
    local ownerRepo="$1"
    local workflows="$2"
    local branch="$3"
    local numberOfDays="$4"
    local commitCountingMethod="$5"
    local patToken="$6"
    local actionsToken="$7"
    local appId="$8"
    local appInstallationId="$9"
    local appPrivateKey="${10}"

    IFS='/' read -r owner repo <<< "$ownerRepo"
    IFS=',' read -r -a workflowsArray <<< "$workflows"

    echo "Owner/Repo: $owner/$repo"
    echo "Workflows: $workflows"
    echo "Branch: $branch"
    echo "Number of days: $numberOfDays"
    echo "Commit counting method: $commitCountingMethod"

    if [[ -n "$patToken" ]]; then
        export GH_TOKEN="$patToken"
    elif [[ -n "$actionsToken" ]]; then
        export GH_TOKEN="$actionsToken"
    fi

    # Get pull requests
    prsResponse=$(gh api "repos/$owner/$repo/pulls?state=all&head=$branch&per_page=100&state=closed")

    prCounter=0
    totalPRHours=0
    for pr in $(echo "$prsResponse" | jq -r '.[] | @base64'); do
        pr=$(echo "$pr" | base64 --decode)
        mergedAt=$(echo "$pr" | jq -r '.merged_at')
        prNumber=$(echo "$pr" | jq -r '.number')
        prMergedAtEpoch=$(date -d "$mergedAt" +%s 2>/dev/null || echo "null")
        cutoffEpoch=$(date -d "$numberOfDays days ago" +%s)

        if [[ -n "$mergedAt" && "$mergedAt" != "null" && "$prMergedAtEpoch" -gt "$cutoffEpoch" ]]; then
            ((prCounter++))
            prCommitsResponse=$(gh api "repos/$owner/$repo/pulls/$prNumber/commits?per_page=100")

            if [[ $(echo "$prCommitsResponse" | jq length) -ge 1 ]]; then
                if [[ "$commitCountingMethod" == "last" ]]; then
                    startDate=$(echo "$prCommitsResponse" | jq -r '.[-1].commit.committer.date')
                elif [[ "$commitCountingMethod" == "first" ]]; then
                    startDate=$(echo "$prCommitsResponse" | jq -r '.[0].commit.committer.date')
                else
                    echo "Commit counting method '$commitCountingMethod' is unknown. Expecting 'first' or 'last'"
                    exit 1
                fi
            fi

            if [[ -n "$startDate" ]]; then
                prTimeDuration=$(($(date -d "$mergedAt" +%s) - $(date -d "$startDate" +%s)))
                totalPRHours=$(echo "$totalPRHours + ($prTimeDuration / 3600)" | bc -l)
            fi
        fi
    done

    # Get workflows
    workflowsResponse=$(gh api "repos/$owner/$repo/actions/workflows" -q '.workflows')

    workflowIds=()
    workflowNames=()
    for workflow in $(echo "$workflowsResponse" | jq -r '.[] | @base64'); do
        workflow=$(echo "$workflow" | base64 --decode)
        workflow_name=$(echo "$workflow" | jq -r '.name')
        workflow_id=$(echo "$workflow" | jq -r '.id')

        for arrayItem in "${workflowsArray[@]}"; do
            if [[ "$workflow_name" == "$arrayItem" ]]; then
                if ! [[ " ${workflowIds[*]} " =~ $workflow_id ]]; then
                    workflowIds+=("$workflow_id")
                fi
                if ! [[ " ${workflowNames[*]} " =~ $workflow_name ]]; then
                    workflowNames+=("$workflow_name")
                fi
            fi
        done
    done

    workflowList=()
    for workflowId in "${workflowIds[@]}"; do
        workflowCounter=0
        totalWorkflowHours=0

        workflowRunsResponse=$(gh api "repos/$owner/$repo/actions/workflows/$workflowId/runs?per_page=100&status=completed" -q '.workflow_runs')

        for run in $(echo "$workflowRunsResponse" | jq -r '.[] | @base64'); do
            run=$(echo "$run" | base64 --decode)
            run_branch=$(echo "$run" | jq -r '.head_branch')
            run_created_at=$(echo "$run" | jq -r '.created_at')
            run_updated_at=$(echo "$run" | jq -r '.updated_at')
            run_created_at_epoch=$(date -d "$run_created_at" +%s)
            run_cutoff_epoch=$(date -d "$numberOfDays days ago" +%s)

            if [[ "$run_branch" == "$branch" && "$run_created_at_epoch" -gt "$run_cutoff_epoch" ]]; then
                ((workflowCounter++))
                workflowDuration=$(($(date -d "$run_updated_at" +%s) - $(date -d "$run_created_at" +%s)))
                totalWorkflowHours=$(echo "$totalWorkflowHours + ($workflowDuration / 3600)" | bc -l)
            fi
        done

        if (( workflowCounter > 0 )); then
            workflowList+=("$totalWorkflowHours|$workflowCounter")
        fi
    done

    totalAverageWorkflowHours=0
    for workflowItem in "${workflowList[@]}"; do
        IFS='|' read -r totalHours counter <<< "$workflowItem"
        counter=$((counter > 0 ? counter : 1))
        totalAverageWorkflowHours=$(echo "$totalAverageWorkflowHours + ($totalHours / $counter)" | bc -l)
    done

    leadTimeForChangesInHours=$(echo "($totalPRHours / $prCounter) + $totalAverageWorkflowHours" | bc -l)
    echo "Lead time for changes in hours: $leadTimeForChangesInHours"

    # Show current rate limit
    rateLimitResponse=$(gh api "rate_limit" -q '.rate')
    rate_used=$(echo "$rateLimitResponse" | jq -r '.used')
    rate_limit=$(echo "$rateLimitResponse" | jq -r '.limit')
    echo "Rate limit consumption: $rate_used / $rate_limit"

    dailyDeployment=24
    weeklyDeployment=$((24 * 7))
    monthlyDeployment=$((24 * 30))
    everySixMonthsDeployment=$((24 * 30 * 6))

    if (( $(echo "$leadTimeForChangesInHours <= 0" | bc -l) )); then
        rating="None"
        color="lightgrey"
        displayMetric=0
        displayUnit="hours"
    elif (( $(echo "$leadTimeForChangesInHours < 1" | bc -l) )); then
        rating="Elite"
        color="brightgreen"
        displayMetric=$(echo "$leadTimeForChangesInHours * 60" | bc -l)
        displayUnit="minutes"
    elif (( $(echo "$leadTimeForChangesInHours <= $dailyDeployment" | bc -l) )); then
        rating="Elite"
        color="brightgreen"
        displayMetric=$(echo "$leadTimeForChangesInHours" | bc -l)
        displayUnit="hours"
    elif (( $(echo "$leadTimeForChangesInHours <= $weeklyDeployment" | bc -l) )); then
        rating="High"
        color="green"
        displayMetric=$(echo "$leadTimeForChangesInHours / 24" | bc -l)
        displayUnit="days"
    elif (( $(echo "$leadTimeForChangesInHours <= $monthlyDeployment" | bc -l) )); then
        rating="High"
        color="green"
        displayMetric=$(echo "$leadTimeForChangesInHours / 24" | bc -l)
        displayUnit="days"
    elif (( $(echo "$leadTimeForChangesInHours <= $everySixMonthsDeployment" | bc -l) )); then
        rating="Medium"
        color="yellow"
        displayMetric=$(echo "$leadTimeForChangesInHours / 24 / 30" | bc -l)
        displayUnit="months"
    else
        rating="Low"
        color="red"
        displayMetric=$(echo "$leadTimeForChangesInHours / 24 / 30" | bc -l)
        displayUnit="months"
    fi

    if (( $(echo "$leadTimeForChangesInHours > 0" | bc -l) && numberOfDays > 0 )); then
        echo "Lead time for changes average over last $numberOfDays days, is $displayMetric $displayUnit, with a DORA rating of '$rating'"
        get_formatted_markdown "${workflowNames[@]}" "$rating" "$displayMetric" "$displayUnit" "$ownerRepo" "$branch" "$numberOfDays" "$color"
    else
        echo "No lead time for changes to display for this workflow and time period"
        get_formatted_markdown_no_result "$workflows" "$numberOfDays"
    fi
}

# Function to get formatted markdown
get_formatted_markdown() {
    local workflowNames=("$1")
    local rating="$2"
    local displayMetric="$3"
    local displayUnit="$4"
    local repo="$5"
    local branch="$6"
    local numberOfDays="$7"
    local color="$8"

    local encodedString
    encodedString=$(echo -n "$displayMetric $displayUnit" | jq -sRr @uri)

    echo -e "\n\n![Lead time for changes](https://img.shields.io/badge/lead_time-$encodedString-$color?logo=github&label=Lead%20time%20for%20changes)\n" \
    "**Definition:** For the primary application or service, how long does it take to go from code committed to code successfully running in production.\n" \
    "**Results:** Lead time for changes is **$displayMetric $displayUnit** with a **$rating** rating, over the last **$numberOfDays days**.\n" \
    "**Details**:\n" \
    "- Repository: $repo using $branch branch\n" \
    "- Workflow(s) used: ${workflowNames[*]}\n" \
    "---"
}

# Function to get formatted markdown for no result
get_formatted_markdown_no_result() {
    local workflows="$1"
    local numberOfDays="$2"

    echo -e "\n\n![Lead time for changes](https://img.shields.io/badge/lead_time-none-lightgrey?logo=github&label=Lead%20time%20for%20changes)\n\n" \
    "No data to display for $ownerRepo over the last $numberOfDays days\n\n" \
    "---"
}

# Parse command-line options
while getopts ":o:w:b:n:c:p:a:i:I:k:hv" opt; do
    case ${opt} in
        o )
            ownerRepo=$OPTARG
            ;;
        w )
            workflows=$OPTARG
            ;;
        b )
            branch=$OPTARG
            ;;
        n )
            numberOfDays=$OPTARG
            ;;
        c )
            commitCountingMethod=$OPTARG
            ;;
        p )
            patToken=$OPTARG
            ;;
        a )
            actionsToken=$OPTARG
            ;;
        i )
            appId=$OPTARG
            ;;
        I )
            appInstallationId=$OPTARG
            ;;
        k )
            appPrivateKey=$OPTARG
            ;;
        h )
            usage
            ;;
        v )
            set -xv
            ;;
        \? )
            echo "Invalid option: -$OPTARG" 1>&2
            usage
            ;;
        : )
            echo "Invalid option: -$OPTARG requires an argument" 1>&2
            usage
            ;;
    esac
done

# Check required parameters
if [ -z "$ownerRepo" ] || [ -z "$workflows" ] || [ -z "$branch" ] || [ -z "$numberOfDays" ] || [ -z "$commitCountingMethod" ]; then
    echo "Missing required parameters" 1>&2
    usage
fi

# Shift off the options and optional --
shift $((OPTIND -1))

# Script entry point
main "$ownerRepo" "$workflows" "$branch" "$numberOfDays" "$commitCountingMethod" "$patToken" "$actionsToken" "$appId" "$appInstallationId" "$appPrivateKey"
