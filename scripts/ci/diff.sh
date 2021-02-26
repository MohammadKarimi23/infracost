#!/bin/sh -le

# This script runs infracost on the current branch then the master branch. It uses `git diff`
# to post a pull-request comment showing the cost estimate difference whenever a percentage
# threshold is crossed.
# Usage docs: https://www.infracost.io/docs/integrations/
# It supports: GitHub Actions, GitLab CI, CircleCI with GitHub and Bitbucket, Bitbucket Pipelines
# For Bitbucket: BITBUCKET_TOKEN must be set to "myusername:my_app_password", the password needs to have Read scope
#   on "Repositories" and "Pull Requests" so it can post comments. Using a Bitbucket App password
#   (https://support.atlassian.com/bitbucket-cloud/docs/app-passwords/) is recommended.

process_args () {
  # Set variables based on the order for GitHub Actions, or the env value for other CIs
  terraform_json_file=${1:-$terraform_json_file}
  terraform_plan_file=${2:-$terraform_plan_file}
  terraform_dir=${3:-$terraform_dir}
  terraform_plan_flags=${4:-$terraform_plan_flags}

  percentage_threshold=${5:-$percentage_threshold}
  usage_file=${6:-$usage_file}
  config_file=${7:-$config_file}

  # Handle deprecated var names
  terraform_json_file=${terraform_json_file:-$tfjson}
  terraform_plan_file=${terraform_plan_file:-$tfplan}
  terraform_dir=${terraform_dir:-$tfdir}
  terraform_plan_flags=${terraform_plan_flags:-$tfflags}

  # Set defaults
  percentage_threshold=${percentage_threshold:-0}
  GITHUB_API_URL=${GITHUB_API_URL:-https://api.github.com}
  BITBUCKET_API_URL=${BITBUCKET_API_URL:-https://api.bitbucket.org}
  # Export as it's used by infracost, not this script
  export INFRACOST_BINARY=${INFRACOST_BINARY:-infracost}
  export INFRACOST_LOG_LEVEL=${INFRACOST_LOG_LEVEL:-info}
  export INFRACOST_CI_DIFF=true

  if [ ! -z "$GIT_SSH_KEY" ]; then
    echo "Setting up private Git SSH key so terraform can access your private modules."
    mkdir -p .ssh
    echo "${GIT_SSH_KEY}" > .ssh/git_ssh_key
    chmod 600 .ssh/git_ssh_key
    export GIT_SSH_COMMAND="ssh -i $(pwd)/.ssh/git_ssh_key -o 'StrictHostKeyChecking=no'"
  fi

  # Bitbucket Pipelines don't have a unique env so use this to detect it
  if [ ! -z "$BITBUCKET_BUILD_NUMBER" ]; then
    BITBUCKET_PIPELINES=true
  fi
}

build_breakdown_cmd () {
  breakdown_cmd="${INFRACOST_BINARY} breakdown --no-color --format=json"

  if [ ! -z "$terraform_json_file" ]; then
    breakdown_cmd="$breakdown_cmd --terraform-json-file $terraform_json_file"
  fi
  if [ ! -z "$terraform_plan_file" ]; then
    breakdown_cmd="$breakdown_cmd --terraform-plan-file $terraform_plan_file"
  fi
  if [ ! -z "$terraform_dir" ]; then
    breakdown_cmd="$breakdown_cmd --terraform-dir $terraform_dir"
  fi
  if [ ! -z "$terraform_plan_flags" ]; then
    breakdown_cmd="$breakdown_cmd --terraform-plan-flags \"$terraform_plan_flags\""
  fi
  if [ ! -z "$usage_file" ]; then
    breakdown_cmd="$breakdown_cmd --usage-file $usage_file"
  fi
  if [ ! -z "$config_file" ]; then
    breakdown_cmd="$breakdown_cmd --config-file $config_file"
  fi
  echo "$breakdown_cmd"
}

build_output_cmd () {
  breakdown_path=$1
  output_cmd="${INFRACOST_BINARY} output --no-color --format=diff $1"
  echo "${output_cmd}"
}

format_cost () {
  cost=$1
    
  if [ -z "$cost" ] | [ "${cost}" == "null" ]; then
    echo "-"
  elif [ $(echo "$cost < 100" | bc -l) = 1 ]; then
    printf "$%0.2f" $cost
  else
    printf "$%0.0f" $cost
  fi
}

build_msg () {
  include_html=$1
  
  change_word="increase"
  change_sym="+"
    change_emoji="📈"
  if [ $(echo "$new_monthly_cost < ${old_monthly_cost}" | bc -l) = 1 ]; then
    change_word="decrease"
    change_sym=""
    change_emoji="📉"
  fi
  
  percent_display=""
  if [ ! -z "$percent" ]; then
    percent_display=" (${change_sym}${percent}%)"
  fi
  
  msg="💰 Infracost estimate: **monthly cost will ${change_word} by $(format_cost $diff_cost)$percent_display** ${change_emoji}\n"
  msg+="\n"
  msg+="Previous monthly cost: $(format_cost $old_monthly_cost)\n"
  msg+="New monthly cost: $(format_cost $new_monthly_cost)\n"
  msg+="\n"
  
  if [ "$include_html" = true ]; then
    msg+="<details>\n"
    msg+="  <summary><strong>Infracost output</strong></summary>\n"
  else
    msg+="**Infracost output:**\n"
  fi
    
  msg+="\n"
  msg+="\`\`\`\n"
  msg+="${diff_output}\n"
  msg+="\`\`\`\n"
  
  if [ "$include_html" = true ]; then
    msg+="</details>\n"
  fi
  
  echo "$msg"
}

post_to_github () {
  if [ "$GITHUB_EVENT_NAME" == "pull_request" ]; then
    GITHUB_SHA=$(cat $GITHUB_EVENT_PATH | jq -r .pull_request.head.sha)
  fi
  
  echo "Posting comment to GitHub commit $GITHUB_SHA"
  msg=$(build_msg true)
  jq -Mnc --arg msg $msg '{"body": ($msg)}' | curl -L -X POST -d @- \
    -H "Content-Type: application/json" \
    -H "Authorization: token $GITHUB_TOKEN" \
    "$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/comments"
}

post_to_gitlab () {
  echo "Posting comment to GitLab commit $CI_COMMIT_SHA"
  msg=$(build_msg true)
  jq -Mnc --arg msg $msg '{"note": ($msg)}' | curl -L -X POST -d @- \
    -H "Content-Type: application/json" \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$CI_SERVER_URL/api/v4/projects/$CI_PROJECT_ID/repository/commits/$CI_COMMIT_SHA/comments"
  # Previously we posted to the merge request, using the comment_key=body above:
  # "$CI_SERVER_URL/api/v4/projects/$CI_PROJECT_ID/merge_requests/$CI_MERGE_REQUEST_IID/notes"
}

post_bitbucket_comment () {
  msg=$(build_msg false)
  jq -Mnc --arg msg $msg '{"content": {"raw": ($msg)}}' | curl -L -X POST -d @- \
    -H "Content-Type: application/json" \
    -u $BITBUCKET_TOKEN \
    "$BITBUCKET_API_URL/2.0/repositories/$1"
}

post_to_circle_ci () {
  if echo $CIRCLE_REPOSITORY_URL | grep -Eiq github; then
    echo "Posting comment from CircleCI to GitHub commit $CIRCLE_SHA1"
    msg=$(build_msg true)
    jq -Mnc --arg msg $msg '{"body": ($msg)}' | curl -L -X POST -d @- \
      -H "Content-Type: application/json" \
      -H "Authorization: token $GITHUB_TOKEN" \
      "$GITHUB_API_URL/repos/$CIRCLE_PROJECT_USERNAME/$CIRCLE_PROJECT_REPONAME/commits/$CIRCLE_SHA1/comments"

  elif echo $CIRCLE_REPOSITORY_URL | grep -Eiq bitbucket; then
    if [ ! -z "$CIRCLE_PULL_REQUEST" ]; then
      BITBUCKET_PR_ID=$(echo $CIRCLE_PULL_REQUEST | sed 's/.*pull-requests\///')

      echo "Posting comment from CircleCI to Bitbucket pull-request $BITBUCKET_PR_ID"
      post_bitbucket_comment "$CIRCLE_PROJECT_USERNAME/$CIRCLE_PROJECT_REPONAME/pullrequests/$BITBUCKET_PR_ID/comments"
    else
      echo "Posting comment from CircleCI to Bitbucket commit $CIRCLE_SHA1"
      post_bitbucket_comment "$CIRCLE_PROJECT_USERNAME/$CIRCLE_PROJECT_REPONAME/commit/$CIRCLE_SHA1/comments"
    fi

  else
    echo "Error: CircleCI is not being used with GitHub or Bitbucket!"
  fi
}

post_to_bitbucket () {
  if [ ! -z "$BITBUCKET_PR_ID" ]; then
    echo "Posting comment to Bitbucket pull-request $BITBUCKET_PR_ID"
    post_bitbucket_comment "$BITBUCKET_REPO_FULL_NAME/pullrequests/$BITBUCKET_PR_ID/comments"
  else
    echo "Posting comment to Bitbucket commit $BITBUCKET_COMMIT"
    post_bitbucket_comment "$BITBUCKET_REPO_FULL_NAME/commit/$BITBUCKET_COMMIT/comments"
  fi
}

# MAIN

process_args

infracost_breakdown_cmd=$(build_breakdown_cmd)
echo "$infracost_breakdown_cmd" > infracost_breakdown_cmd

echo "Running infracost breakdown using:"
echo "  $ $(cat infracost_breakdown_cmd)"
breakdown_output=$(cat infracost_breakdown_cmd | sh)
echo "$breakdown_output" > infracost_breakdown.json

infracost_output_cmd=$(build_output_cmd "infracost_breakdown.json")
echo "$infracost_output_cmd" > infracost_output_cmd
  
echo "Running infracost output using:"
echo "  $ $(cat infracost_output_cmd)"
diff_output=$(cat infracost_output_cmd | sh)

old_monthly_cost=$(jq '[.projects[].pastBreakdown.totalMonthlyCost | select (.!=null) | tonumber] | add' infracost_breakdown.json)
new_monthly_cost=$(jq '[.projects[].breakdown.totalMonthlyCost | select (.!=null) | tonumber] | add' infracost_breakdown.json)
diff_cost=$(jq '[.projects[].diff.totalMonthlyCost | select (.!=null) | tonumber] | add' infracost_breakdown.json)

# If both old and new costs are greater than 0
if [ $(echo "$old_monthly_cost > 0" | bc -l) = 1 ] && [ $(echo "$new_monthly_cost > 0" | bc -l) = 1 ]; then
  percent=$(echo "scale=4; $new_monthly_cost / $old_monthly_cost * 100 - 100" | bc)
  percent="$(printf "%.0f" $percent)"
fi

# If both old and new costs are less than or equal to 0
if [ $(echo "$old_monthly_cost <= 0" | bc -l) = 1 ] && [ $(echo "$new_monthly_cost <= 0" | bc -l) = 1 ]; then
  percent=0
fi

absolute_percent=$(echo $percent | tr -d -)

if [ -z "$percent" ]; then
  echo "Diff percentage is empty"
elif [ $(echo "$absolute_percent > $percentage_threshold" | bc -l) = 1 ]; then
  echo "Diff ($absolute_percent%) is greater than the percentage threshold ($percentage_threshold%)."
else
  echo "Comment not posted as diff ($absolute_percent%) is less than or equal to percentage threshold ($percentage_threshold%)."
  exit 0
fi

if [ ! -z "$GITHUB_ACTIONS" ]; then
  post_to_github
elif [ ! -z "$GITLAB_CI" ]; then
  post_to_gitlab
elif [ ! -z "$CIRCLECI" ]; then
  post_to_circle_ci
elif [ ! -z "$BITBUCKET_PIPELINES" ]; then
  post_to_bitbucket
fi

exit
