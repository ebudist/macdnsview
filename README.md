# MacDNSView

Look up DNS records for many domains and IP addresses at once, against your system resolver or any DNS server, and export the results. A native macOS app plus a CLI.

Status: 0.1, the first release. Expect rough edges.

## Features

- Record types: A, AAAA, CNAME, MX, NS, SOA, SRV, TXT, CAA, DMARC, and PTR for IP addresses.
- Any DNS server, or the system configuration including VPN scoped servers.
- TTL, response section, and answering server on every row.
- Export to CSV, TSV, JSON, plain text, and HTML.
- CLI for scripts: `macdnsview example.com 1.1.1.1 --type A,MX --format json`

## Install

Download `MacDNSView-<version>.zip` (the app) or `macdnsview-cli-<version>.zip` (the CLI) from [Releases](https://github.com/ebudist/macdnsview/releases). Both are universal binaries for Apple silicon and Intel, macOS 14 or later.

The builds are ad-hoc signed, not notarized, so Gatekeeper blocks them the first time. After unzipping, clear the quarantine flag:

```
xattr -d com.apple.quarantine MacDNSView.app
xattr -d com.apple.quarantine macdnsview
```

Move `MacDNSView.app` to `/Applications` and `macdnsview` to a directory on your `PATH`, such as `/usr/local/bin`.

## Build

Requires macOS 14 and Swift 6 (Command Line Tools are enough).

```
swift build
swift test -j 1
swift run macdnsview example.com 1.1.1.1
swift run macdnsview --help
scripts/bundle.sh    # universal MacDNSView.app and CLI, zipped into dist/
```

## Credits

Inspired by [DNSDataView](https://www.nirsoft.net/utils/dns_records_viewer.html) by Nir Sofer, which is Windows only. MacDNSView is an independent reimplementation and is not affiliated with NirSoft.

## License

MIT
