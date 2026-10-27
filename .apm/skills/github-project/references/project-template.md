# Project template

GravionLabs is a user account, so `markProjectV2AsTemplate` (organizations only) does not apply. The template is a normal project named "Project Template" at number `15` (https://github.com/users/GravionLabs/projects/15), copied from APM Hub (#5), the reference instance. It carries the UI-only settings ("Show hierarchy", sort of Recently closed); change those in #5 and the template together.

## New project for a repo

1. Look up ids:

```powershell
gh api graphql -f query='query($l:String!,$n:Int!){user(login:$l){id projectV2(number:$n){id}}}' -f l=GravionLabs -F n=15
gh repo view GravionLabs/<repo> --json id
```

2. Copy without draft issues:

```powershell
gh api graphql -f query='mutation($o:ID!,$p:ID!,$t:String!){copyProjectV2(input:{ownerId:$o,projectId:$p,title:$t,includeDraftIssues:false}){projectV2{id number url}}}' -f o=<user-id> -f p=<template-project-id> -f t='<repo>'
```

3. Link it to the repository:

```powershell
gh api graphql -f query='mutation($p:ID!,$r:ID!){linkProjectV2ToRepository(input:{projectId:$p,repositoryId:$r}){clientMutationId}}' -f p=<new-project-id> -f r=<repo-id>
```

4. Run `pwsh scripts/Set-ProjectStandard.ps1 -Owner GravionLabs -Number <new-nr> -Sync -RemoveDefaultViews`, then the manual UI steps it prints (copies keep views and fields, but the workflow "Item closed → Done" and "Show hierarchy" should be checked).
