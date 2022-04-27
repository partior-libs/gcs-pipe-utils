
#!/bin/bash +e

targetRepo="$1"
prNum="$2"

gh pr list --repo ${targetRepo}

gh pr view ${prNum} --json state,statusCheckRollup,isDraft,url --repo ${targetRepo}