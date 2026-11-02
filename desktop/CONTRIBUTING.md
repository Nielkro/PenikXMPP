# Contributing to DinoX

DinoX accepts bug reports, feature requests, and pull requests on Forgejo:

- Issues: https://git.dinox.im/dinoxim/dinox/issues
- Pull requests: https://git.dinox.im/dinoxim/dinox/pulls

Contributor accounts are manually approved. Regular users cannot create
repositories or organizations on the DinoX Forgejo instance. Repository forks
and repository migrations are intentionally disabled.

For code contributions, use Forgejo AGit instead of forks:

```bash
git clone ssh://git@git.dinox.im:2222/dinoxim/dinox.git
cd dinox
git checkout -b fix-short-topic
# edit, build, test, commit
git push origin HEAD:refs/for/master -o topic="fix-short-topic"
```

Use the same `topic` when updating the pull request.

For the full contributor guide, including build and test expectations, see
[docs/internal/CONTRIBUTING.md](docs/internal/CONTRIBUTING.md).
