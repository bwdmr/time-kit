# Contributing

Contributions are welcome.

Please follow these steps when making changes.

---

## Contribution steps

1. Create an issue describing the problem or change.
  - Add an UTC Timestamp at the top of the issue. (`date -u +%s`) 

2. Fork the repository.

3. Create a branch for each PR you intend to make.
  - Format: `docs_readme_contribute`, max 3 words in snake case
  - the first word a category. the second the section affected. the third what is to change.

4. Make your first commit on that branch and include the issue number and the issue timestamp as first two elements in the commit body:
  - indicate the category of the commit as in type.
  - indicate affected source of the change.
  - follow the commit with a title that describes what has changed not why.
  - complete example:

```yaml
docs(readme): Fix Typo

- timestamp: 1768991151
- issue: https://github.com/.../issues/1
```

5. Update the `changelog.json` with the script `generate_changelog.sh`.
  - add as a separate commit.

6. Open a pull request.

7. Wait for the pull request to be reviewed.

8. ??

9. Profit

---
