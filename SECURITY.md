# Security

Please report suspected vulnerabilities privately through GitHub's security advisory workflow for this repository. Include a synthetic reproduction and affected version. Do not include customer addresses, credentials, raw production notifications or certificate tokens in a public issue.

Bouncy's SNS receiver is a public write path. A valid AWS signature alone does not authorize the sender: configure exact topic ARNs and restrict the topic's publisher policy to the intended SES source account and identities. See [Amazon SES setup](guides/amazon-ses.md).

The first release supports one account-level SES suppression scope. Hosts own tenant authorization, administrative recovery permissions and safe rendering of event diagnostics. Provider recovery may affect other apps using the same account and region.
