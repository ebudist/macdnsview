# MacDNSView

A macOS app and CLI that looks up DNS records for a list of names or addresses against any DNS server and exports the results.

## Language

**Target**:
One line of user input to look up: a domain name, an IP address (looked up in reverse as PTR), or a URL (reduced to its host).
_Avoid_: domain, host, query

**Record**:
One resource record from a DNS response, shown as one row.
_Avoid_: entry, result, item

**Error row**:
A row that stands in for a Record when a lookup for a Target and type fails, carrying the failure code instead of data.
_Avoid_: failed record

**Section**:
The part of the DNS response a Record came from: Answer, Authority, or Additional.

**Server**:
The DNS server a lookup is sent to, either chosen by the user or picked from the system resolver configuration.
_Avoid_: resolver, nameserver (except when meaning the NS record)

**Scoped server**:
A system-configured Server that only applies to names under certain domains, such as a VPN's internal zone.
_Avoid_: split DNS server, supplemental resolver

**Lookup options**:
The record types and follow-up rules chosen for a run, such as reverse lookup of IP addresses found in answers.
_Avoid_: settings, DNS options
