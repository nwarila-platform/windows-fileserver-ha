#!/usr/bin/env python3
"""Builds the ports, protocols and services register and its boundary diagram from the security group inputs.

Every per-host rule in terraform/aws.tfvars, every rule of the shared domain member group and both WireGuard gateway
directions must be bound to a register row, and every binding to a security group must match a real rule. A bound row's port, protocol and
address scope are read from and checked against those rules, or the build fails. --check rebuilds the committed
outputs and fails on any difference. Rows not bound to a group, the wording of sources and destinations, and the prose
outside the register table are annotations the build does not check; nor does it check which security groups each network interface attaches, or which
host carries a bound rule. site-gateway.json takes its rules from the gateway repository's terraform/resources.tf, which
must express them as aws_vpc_security_group_*_rule resources, and their variable values from its terraform/aws.tfvars;
rules written in other files, overrides or modules, and variable values set anywhere else, are not read.

Usage (from anywhere; paths default to this repository):
  build.py                                   rebuild README.md and diagram.svg beside this script
  build.py --check                           fail if the committed README.md or diagram.svg is out of date
  build.py --site public --stamp <commit>    write the published page (index.html, diagram.svg) to public/
  build.py --snapshot-gateway <aws-site-gateway clone> --gateway-ref <commit>
                                             refresh site-gateway.json from that repository at that commit
"""
import argparse
import difflib
import html
import json
import pathlib
import re
import subprocess
import sys

import hcl2
import jinja2
from markupsafe import Markup

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
COMMITTED = ('README.md', 'diagram.svg')
EXPECTED_SLOTS = {'node_a1', 'node_a2', 'node_b1', 'node_b2', 'witness'}
REQUIRED_GATEWAY_RULES = {('ingress', 'wireguard'), ('egress', 'wireguard')}
EXTERNAL_REFERENCE = re.compile(r'(?i)(?:https?:)?[/\\]{2}|\bhttps?:|@import|@font-face|url\(\s*[^#]')
OTHER_RULE_TYPES = ('aws_security_group_rule', 'aws_network_acl_rule')
READ_RULE_TYPES = {'aws_vpc_security_group_ingress_rule', 'aws_vpc_security_group_egress_rule'}
RULE_FREE_TYPES = {'aws_iam_role', 'aws_iam_role_policy', 'aws_iam_instance_profile', 'aws_security_group',
                   'aws_network_interface', 'aws_eip', 'aws_instance', 'aws_route'}
BADGE = re.compile(r'<g class="badge b-[a-z]+"><circle [^>]*/><text [^>]*>([^<]+)</text></g>')
PEER = re.compile(r' (?:from|to) (\S+)$')
GATEWAY_GROUP = '${aws_security_group.gateway.id}'
SHARED_GROUP = '${aws_security_group.domain_member.id}'
SHARED_RULES = '${local.domain_member_egress}'
DECLARED_KINDS = {'framework', 'platform', 'not-permitted', 'gap'}
ENFORCED_BY = {'host': 'Per-host groups', 'witness': 'Witness group', 'shared': 'Shared group',
               'gateway-ingress': 'Gateway group (any source)', 'gateway-egress': 'Gateway group (any destination)',
               'framework': 'Run-scoped group', 'platform': 'AWS platform', 'not-permitted': 'Not permitted',
               'gap': 'Not permitted'}


def unq(value):
    """python-hcl2 keeps the quotes of string literals and block labels; strip them recursively."""
    if isinstance(value, str) and len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    if isinstance(value, list):
        return [unq(v) for v in value]
    if isinstance(value, dict):
        return {unq(k): unq(v) for k, v in value.items() if not k.startswith('__')}
    return value


def git_text(repo, *arguments):
    result = subprocess.run(['git', '-C', str(repo), *arguments],
                            check=False, capture_output=True, text=True)
    if result.returncode:
        detail = result.stderr.strip() or f'git exited {result.returncode}'
        raise RuntimeError(f"git {' '.join(arguments)} failed: {detail}")
    return result.stdout


def snapshot_gateway(repo, ref, target):
    """Record the shared group and gateway rules from terraform/resources.tf, with variable values from
    terraform/aws.tfvars, as committed at ref, so the build needs no gateway clone. Rule forms this snapshot does not
    read fail by name instead of being skipped."""
    commit = git_text(repo, 'rev-parse', '--verify', f'{ref}^{{commit}}').strip()

    def read(path):
        return unq(hcl2.loads(git_text(repo, 'show', f'{commit}:{path}')))

    tfvars = read('terraform/aws.tfvars')
    resources = read('terraform/resources.tf')

    def value(v):
        if not (isinstance(v, str) and v.startswith('${var.')):
            return v
        name = v[len('${var.'):-1]
        if name not in tfvars:
            raise RuntimeError(f'gateway variable {name} has no value in terraform/aws.tfvars at {commit}')
        return tfvars[name]

    def rule(body):
        return {'ip_protocol': value(body['ip_protocol']), 'from_port': value(body.get('from_port', -1)),
                'to_port': value(body.get('to_port', -1)), 'cidr_ipv4': value(body.get('cidr_ipv4'))}

    shared, shared_sets, gateway = {}, [], {'ingress': {}, 'egress': {}}
    for block in resources.get('resource', []):
        for kind, resources_of_kind in block.items():
            if kind in OTHER_RULE_TYPES:
                raise RuntimeError(f'{kind} {sorted(resources_of_kind)} is a rule form this snapshot does not read ({commit})')
            for name, body in resources_of_kind.items():
                inline = {key for key in ('ingress', 'egress') if key in body}
                inline |= {key for entry in body.get('dynamic', []) for key in entry if key in ('ingress', 'egress')}
                if inline:
                    raise RuntimeError(f'{kind} {name} declares inline {sorted(inline)} rules, which this snapshot '
                                       f'does not read ({commit})')
            if kind not in READ_RULE_TYPES | RULE_FREE_TYPES:
                raise RuntimeError(f'{kind} {sorted(resources_of_kind)} is a resource type this snapshot does not read '
                                   f'({commit})')
        for direction in gateway:
            for name, body in block.get(f'aws_vpc_security_group_{direction}_rule', {}).items():
                group = body.get('security_group_id')
                if 'count' in body:
                    raise RuntimeError(f'{direction} rule {name} uses count, which this snapshot does not expand ({commit})')
                if group == SHARED_GROUP:
                    if direction != 'egress' or body.get('for_each') != SHARED_RULES:
                        raise RuntimeError(f'{direction} rule {name} on the shared domain member group is not the '
                                           f'egress rule set this register covers ({commit})')
                    if 'cidr_ipv4' not in body:
                        raise RuntimeError(f'shared rule set {name} has no cidr_ipv4 ({commit})')
                    if any(body.get(field) != f'${{each.value.{field}}}' for field in ('ip_protocol', 'from_port', 'to_port')):
                        raise RuntimeError(f'shared rule set {name} overrides the protocol or ports of '
                                           f'local.domain_member_egress ({commit})')
                    shared_sets.append((name, value(body['cidr_ipv4'])))
                elif group == GATEWAY_GROUP and 'for_each' not in body:
                    gateway[direction][name] = rule(body)
                else:
                    raise RuntimeError(f'{direction} rule {name} on {group} is neither a single gateway rule nor the '
                                       f'shared domain member rule set ({commit})')
    if len(shared_sets) != 1:
        raise RuntimeError(f'expected exactly one rule set on the shared domain member group at {commit}, '
                           f'found {[name for name, _ in shared_sets]}')
    shared_cidr = shared_sets[0][1]
    for block in resources.get('locals', []):
        for key, body in block.get('domain_member_egress', {}).items():
            shared[key] = {**rule(body), 'cidr_ipv4': shared_cidr}
    recorded = [(f'domain_member_egress.{key}', fields) for key, fields in shared.items()]
    recorded += [(f'gateway_rules.{direction}.{name}', fields)
                 for direction in gateway for name, fields in gateway[direction].items()]
    for where, fields in recorded:
        for field, field_value in fields.items():
            if isinstance(field_value, str) and '${' in field_value:
                raise RuntimeError(f'{where} {field} is the expression {field_value}, which this snapshot cannot '
                                   f'resolve ({commit})')
    snapshot = {'source': {'repository': 'aws-site-gateway', 'commit': commit},
                'domain_controller_cidr': tfvars['domain_controller_cidr'],
                'domain_member_group_name': tfvars['domain_member_group_name'],
                'domain_member_egress': shared, 'gateway_rules': gateway}
    target.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + '\n', encoding='utf-8', newline='')
    print(f'wrote {target.name} from aws-site-gateway {commit}')


def fmt_port(proto, low, high):
    if proto == '-1':
        return 'any'
    if proto == 'icmp':
        if (low, high) == (-1, -1):
            return 'all'
        if (low, high) == (8, 0):
            return 'echo'
        return f'type {low}, code {high}'
    return str(low) if low == high else f'{low}–{high}'


def load_hosts(tfvars):
    with open(tfvars, encoding='utf-8') as handle:
        systems = unq(hcl2.load(handle))['all_systems']
    hosts, rules = {}, []
    for system in systems:
        name = system['hostname']
        for nic_index, nic in enumerate(system['network_interfaces']):
            hosts.setdefault(name, {'az': system['availability_zone'], 'subnet_id': system['subnet_id'],
                                    'private_ip': nic.get('private_ip'),
                                    'additional': nic.get('additional_private_ips') or []})
            for direction in ('ingress', 'egress'):
                for index, rule in enumerate(nic.get(direction) or []):
                    rules.append({'id': (name, nic_index, direction, index), 'host': name, 'direction': direction,
                                  'description': rule['description'], 'proto': rule['ip_protocol'],
                                  'from': rule['from_port'], 'to': rule['to_port'], 'cidr': rule.get('cidr_ipv4')})
    return hosts, rules


def nonempty(value):
    return isinstance(value, str) and value != ''


def bind(register, hosts, host_rules, gateway, context, errors):
    """Resolve each row's port and protocol from the rules it binds, check their address scope, and record every rule
    left unbound."""
    shared, dc_cidr = gateway['domain_member_egress'], gateway['domain_controller_cidr']
    if not nonempty(dc_cidr):
        errors.append('site-gateway.json domain_controller_cidr must be a non-empty string')
    claimed_host = {rule['id']: [] for rule in host_rules}
    claimed_shared, claimed_gateway, flows = set(), set(), []
    for flow in register['flows']:
        rows = []
        for row in flow['rows']:
            matched, kinds = [], []
            for binding in row['binding']:
                kind = binding.get('kind')
                if kind == 'host':
                    has_cidr, peer_scope = 'cidr' in binding, binding.get('peer_scope') is True
                    if has_cidr and not nonempty(binding['cidr']):
                        errors.append(f"{row['ref']}: host binding cidr must be a non-empty string")
                    if 'peer_scope' in binding and not isinstance(binding['peer_scope'], bool):
                        errors.append(f"{row['ref']}: host binding peer_scope must be a boolean")
                    if not (has_cidr and nonempty(binding['cidr'])) and not peer_scope:
                        errors.append(f"{row['ref']}: a host binding must declare cidr or peer_scope")
                    hits = [r for r in host_rules
                            if binding.get('direction') in (None, r['direction'])
                            and re.fullmatch(binding['description'], r['description'])
                            and (not has_cidr or r['cidr'] == binding['cidr'])]
                    if not hits:
                        errors.append(f"{row['ref']}: no per-host rule matches {binding}")
                    for rule in hits:
                        claimed_host[rule['id']].append((row['ref'], binding.get('allow_shared_rule', False)))
                        if peer_scope:
                            peer = PEER.search(rule['description'])
                            address = hosts.get(peer.group(1), {}).get('private_ip') if peer else None
                            if address is None or rule['cidr'] != f'{address}/32':
                                errors.append(f"{row['ref']}: rule on {rule['host']} '{rule['description']}' admits "
                                              f"{rule['cidr']}, not the named peer's address")
                    matched += [(r['proto'], r['from'], r['to']) for r in hits]
                    witness_only = hits and all(hosts[r['host']]['private_ip'] is None for r in hits)
                    kinds.append('witness' if witness_only else 'host')
                elif kind == 'shared':
                    keys = binding.get('keys')
                    if not (isinstance(keys, list) and keys and all(nonempty(key) for key in keys)):
                        errors.append(f"{row['ref']}: a shared binding must list at least one key")
                        keys = []
                    for key in keys:
                        if key not in shared:
                            errors.append(f"{row['ref']}: shared group has no rule '{key}'")
                            continue
                        claimed_shared.add(key)
                        if not nonempty(shared[key].get('cidr_ipv4')):
                            errors.append(f"shared group rule '{key}' has no cidr_ipv4")
                        elif shared[key]['cidr_ipv4'] != dc_cidr:
                            errors.append(f"shared group rule '{key}' targets {shared[key]['cidr_ipv4']}, "
                                          f"not the domain controllers {dc_cidr}")
                        matched.append((shared[key]['ip_protocol'], shared[key]['from_port'], shared[key]['to_port']))
                    kinds.append(kind)
                elif kind == 'gateway':
                    rule = gateway['gateway_rules'][binding['direction']].get(binding['rule'])
                    if not nonempty(binding.get('cidr')):
                        errors.append(f"{row['ref']}: gateway binding cidr must be a non-empty string")
                    elif rule is None:
                        errors.append(f"{row['ref']}: site gateway has no {binding['direction']} rule '{binding['rule']}'")
                    elif not nonempty(rule.get('cidr_ipv4')):
                        errors.append(f"{row['ref']}: gateway {binding['direction']} rule '{binding['rule']}' has no cidr_ipv4")
                    else:
                        matched.append((rule['ip_protocol'], rule['from_port'], rule['to_port']))
                        claimed_gateway.add((binding['direction'], binding['rule']))
                        if rule['cidr_ipv4'] != binding['cidr']:
                            errors.append(f"{row['ref']}: gateway {binding['direction']} rule '{binding['rule']}' "
                                          f"admits {rule['cidr_ipv4']}, not {binding['cidr']}")
                    kinds.append(f"gateway-{binding['direction']}")
                elif kind in DECLARED_KINDS:
                    if not (nonempty(binding.get('proto')) and nonempty(binding.get('port'))):
                        errors.append(f"{row['ref']}: a {kind} binding must declare proto and port as non-empty strings")
                    else:
                        matched.append(('declared', binding['proto'], binding['port']))
                    kinds.append(kind)
                else:
                    errors.append(f"{row['ref']}: unknown binding kind {kind!r}")
                    kinds.append('unknown')
            if not kinds:
                errors.append(f"{row['ref']}: a row needs at least one binding")
                kinds.append('unknown')
            protos, ports = [], set()
            for proto, low, high in matched:
                if proto == 'declared':
                    names = [p.upper() for p in low.split('+')]
                    ports.add(high)
                else:
                    names = ['ALL' if proto == '-1' else proto.upper()]
                    ports.add(fmt_port(proto, low, high))
                protos += [n for n in names if n not in protos]
            if len(ports) > 1:
                errors.append(f"{row['ref']}: bound rules disagree on port: {sorted(ports)}")
            rows.append({**row, 'port': next(iter(ports), ''), 'proto': '/'.join(protos),
                         'enforced_by': row.get('enforced_by') or ENFORCED_BY.get(kinds[0], kinds[0]),
                         'source': row['source'].format_map(context),
                         'destination': row['destination'].format_map(context)})
        flows.append({**flow, 'scope': flow.get('scope', '').format_map(context), 'rows': rows})
    for rule in host_rules:
        claims = claimed_host[rule['id']]
        if not claims:
            errors.append(f"unregistered per-host rule on {rule['host']}: {rule['direction']} "
                          f"'{rule['description']}' {rule['proto']} {rule['from']}-{rule['to']} {rule['cidr']}")
        elif len(claims) > 1 and not all(allowed for _, allowed in claims):
            errors.append(f"per-host rule on {rule['host']} '{rule['description']}' is claimed by multiple rows: "
                          f"{[ref for ref, _ in claims]}")
    for key in sorted(set(shared) - claimed_shared):
        errors.append(f"unregistered shared group rule '{key}'")
    for direction, name in sorted(REQUIRED_GATEWAY_RULES - claimed_gateway):
        errors.append(f"unregistered required gateway rule '{direction}.{name}'")
    return flows


def line_breaks(value, path):
    if isinstance(value, str):
        return [path] if '\n' in value or '\r' in value else []
    if isinstance(value, dict):
        keys = [f'{path}.{key!r}' for key in value if '\n' in key or '\r' in key]
        return keys + [found for key, item in value.items() for found in line_breaks(item, f'{path}.{key!r}')]
    if isinstance(value, list):
        return [found for index, item in enumerate(value) for found in line_breaks(item, f'{path}[{index}]')]
    return []


def validate_topology(topology, hosts, errors):
    slots = topology.get('slots', {})
    missing_slots = sorted(EXPECTED_SLOTS - set(slots))
    extra_slots = sorted(set(slots) - EXPECTED_SLOTS)
    if missing_slots or extra_slots:
        errors.append(f'topology slots differ: missing={missing_slots}, extra={extra_slots}')
    names = list(slots.values())
    if len(names) != len(set(names)):
        errors.append('topology slots must name five distinct hosts')
    missing_hosts = sorted(set(hosts) - set(names))
    unknown_hosts = sorted(set(names) - set(hosts))
    if missing_hosts or unknown_hosts:
        errors.append(f'topology hosts differ: missing={missing_hosts}, unknown={unknown_hosts}')


def external_reference(output):
    scrubbed = output.replace('xmlns="http://www.w3.org/2000/svg"', '')
    return EXTERNAL_REFERENCE.search(scrubbed) or EXTERNAL_REFERENCE.search(html.unescape(scrubbed))


def host_view(hosts, topology):
    view = {}
    for slot, name in topology['slots'].items():
        host, cidr = hosts[name], topology['subnets'][hosts[name]['subnet_id']]
        if host['private_ip']:
            suffixes = ''.join(' · .' + ip.rsplit('.', 1)[1] for ip in host['additional'])
            view[slot] = {'name': name, 'ip_line': host['private_ip'] + suffixes, 'az_line': f"{host['az']} · {cidr}"}
        else:
            view[slot] = {'name': name, 'ip_line': f'{cidr} (DHCP)', 'az_line': f"{host['az']} · file share witness"}
    return view


def render(args):
    register = json.loads((args.dir / 'register.json').read_text(encoding='utf-8'))
    topology = json.loads((args.dir / 'topology.json').read_text(encoding='utf-8'))
    gateway = json.loads((args.dir / 'site-gateway.json').read_text(encoding='utf-8'))
    hosts, host_rules = load_hosts(args.tfvars)
    context = {'dc_cidr': gateway['domain_controller_cidr'], 'shared_group': gateway['domain_member_group_name'],
               'gateway': topology['site_gateway']['name']}
    errors = [f'{path}: line breaks are not allowed' for path in line_breaks(register, 'register.json')]
    if errors:
        print('the register does not match the security group rules:', *errors, sep='\n  ', file=sys.stderr)
        return None
    validate_topology(topology, hosts, errors)
    flows = bind(register, hosts, host_rules, gateway, context, errors)
    if errors:
        print('the register does not match the security group rules:', *errors, sep='\n  ', file=sys.stderr)
        return None

    env = jinja2.Environment(loader=jinja2.FileSystemLoader(HERE / 'templates'), keep_trailing_newline=True,
                             autoescape=True, undefined=jinja2.StrictUndefined)
    env.filters['cell'] = lambda text: str(text).replace('|', '\\|')
    tokens_css = (HERE / 'templates/tokens.css').read_text(encoding='utf-8')
    diagram_css = (HERE / 'templates/diagram.css').read_text(encoding='utf-8')
    view = {'t': topology, 'reg': register, 'flows': flows, 'hosts': host_view(hosts, topology),
            'gateway_commit': gateway['source']['commit'], 'stamp': args.stamp,
            'counts': {'host_rules': len(host_rules), 'shared_rules': len(gateway['domain_member_egress'])}}
    try:
        diagram = env.get_template('diagram.svg.j2')
        outputs = {
            'README.md': env.get_template('README.md.j2').render(**view),
            'diagram.svg': diagram.render(**view, standalone=True, css=Markup(tokens_css + diagram_css)),
            'index.html': env.get_template('page.html.j2').render(
                **view, tokens_css=Markup(tokens_css), diagram_css=Markup(diagram_css),
                diagram_svg=Markup(diagram.render(**view, standalone=False, css=''))),
        }
    except jinja2.TemplateError as error:
        print(f'template error: {type(error).__name__}: {error}', file=sys.stderr)
        return None
    drawn = set(BADGE.findall(outputs['diagram.svg']))
    undrawn = [f['id'] for f in flows if f['id'] not in drawn]
    if undrawn:
        print(f'flows not drawn in the diagram: {undrawn}', file=sys.stderr)
        return None
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--tfvars', type=pathlib.Path, default=ROOT / 'terraform/aws.tfvars')
    parser.add_argument('--dir', type=pathlib.Path, default=HERE, help='register inputs and committed outputs')
    parser.add_argument('--check', action='store_true', help='fail if the committed outputs differ from a rebuild')
    parser.add_argument('--site', type=pathlib.Path, help='write the published page here instead of the committed outputs')
    parser.add_argument('--stamp', help='commit to print on the published page; never on the committed outputs')
    parser.add_argument('--snapshot-gateway', type=pathlib.Path, help='an aws-site-gateway clone to snapshot')
    parser.add_argument('--gateway-ref', help='the aws-site-gateway commit to snapshot')
    args = parser.parse_args()

    if args.snapshot_gateway:
        if not args.gateway_ref:
            parser.error('--snapshot-gateway needs --gateway-ref')
        try:
            snapshot_gateway(args.snapshot_gateway, args.gateway_ref, args.dir / 'site-gateway.json')
        except RuntimeError as error:
            parser.exit(1, f'build.py: error: {error}\n')
        return 0
    if args.stamp and not args.site:
        parser.error('--stamp applies only to --site')
    outputs = render(args)
    if outputs is None:
        return 1
    for name in ('index.html', 'diagram.svg'):
        match = external_reference(outputs[name])
        if match:
            print(f"{name} contains a forbidden external reference: {match.group(0)}", file=sys.stderr)
            return 1
    if args.check:
        stale = []
        for name in COMMITTED:
            path = args.dir / name
            current = path.read_bytes().decode('utf-8') if path.exists() else ''
            if current != outputs[name]:
                stale.append(name)
                sys.stderr.writelines(difflib.unified_diff(current.splitlines(True), outputs[name].splitlines(True),
                                                           f'committed/{name}', f'rebuilt/{name}', n=1))
        if stale:
            print(f"\n{', '.join(stale)} out of date: run build.py and commit the result.", file=sys.stderr)
            return 1
        print('the ports and protocols register is current')
        return 0
    if args.site:
        args.site.mkdir(parents=True, exist_ok=True)
        for name in ('index.html', 'diagram.svg'):
            (args.site / name).write_text(outputs[name], encoding='utf-8', newline='')
        print(f'wrote the published page to {args.site}')
        return 0
    for name in COMMITTED:
        (args.dir / name).write_text(outputs[name], encoding='utf-8', newline='')
    print(f"rebuilt {', '.join(COMMITTED)}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
