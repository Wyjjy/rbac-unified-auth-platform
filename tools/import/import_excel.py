#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
import_excel.py — 市政公司统一权限管理平台 · 第一阶段离线数据初始化
后端 D1 整理，2026-10-15。依据《开发设计文档 V3.1》§7 编写。

职责（§7.5 执行顺序）：
  组织(111节点, 负责人留空) → 员工(10000, 按唯一工号) → 负责人回填
  → 应用(15) → 权限定义 → 五类角色 → 已确认角色权限
本脚本为「离线初始化」：只产出 4 份清单 + 一份基线 SQL，不直连数据库。

产物（输出到 output/，均不携带密码、电话明文或部署密钥）：
  source-manifest.json   文件名 / SHA-256 / 数据行数 / 映射版本
  code-mappings.json     源应用·模块·功能·动作 与稳定编码的对应（幂等复用）
  grant-mappings.csv     435 个授权单元格的全部处理结果
  validation-report.json 校验统计与待确认事项
  baseline_data.sql      可直接灌库的基线数据（重跑将主键冲突报错，不静默覆盖）

用法：
  python import_excel.py --src-dir <三份Excel所在目录> --out-dir <输出目录>
依赖：仅 Python 3.8+ 标准库（xlsx 以 zipfile+正则解析，无需 openpyxl）。
"""

import argparse
import csv
import hashlib
import json
import os
import re
import sys
import zipfile
from collections import OrderedDict
from datetime import datetime, timezone

# ---------------------------------------------------------------- 常量 ----

# §7.4 动作字典：32 个中文动作 → 英文码。未知动作必须使校验失败。
ACTION_MAP = {
    '查看': 'view',       '新增': 'create',     '编辑': 'edit',
    '导出': 'export',     '审批': 'approve',    '审核': 'review',
    '登记': 'register',   '转发': 'forward',    '拟稿': 'draft',
    '归档': 'archive',    '组织': 'organize',   '发布': 'publish',
    '打分': 'score',      '报名': 'enroll',     '借阅': 'borrow',
    '申请': 'apply',      '打卡': 'check_in',   '处理': 'handle',
    '上报': 'report',     '派发': 'dispatch',   '接收': 'receive',
    '反馈': 'feedback',   '验收': 'accept',     '发起': 'initiate',
    '主持': 'host',       '推送': 'push',       '检索': 'search',
    '学习': 'learn',      '参加考试': 'take_exam', '阅卷': 'grade',
    '统计': 'statistics', '处置': 'dispose',
}

# 授权清单 5 个角色列：列字母 → role_key / 中文名（§7.4，不建继承边）
ROLE_COLS = [
    ('E', 'SYS_ADMIN',      '系统管理员'),
    ('F', 'COMPANY_LEADER', '公司领导'),
    ('G', 'DEPT_MANAGER',   '部门经理'),
    ('H', 'PROJECT_MANAGER', '项目经理'),
    ('I', 'EMPLOYEE',       '普通员工'),
]

FILE_EMP = '市政公司员工信息表.xlsx'
FILE_DEPT = '市政公司部门信息表.xlsx'
FILE_PERM = '市政公司应用软件功能权限清单.xlsx'

MAPPING_VERSION = 1

# ---------------------------------------------------------------- xlsx ----

def load_xlsx(path):
    """解析 xlsx → [(sheet_name, {row_no: {col: value}}), ...] 按工作簿顺序。
    纯标准库实现：sharedStrings + workbook rels 定位 + 正则抽取。"""
    z = zipfile.ZipFile(path)
    shared = []
    if 'xl/sharedStrings.xml' in z.namelist():
        ss = z.read('xl/sharedStrings.xml').decode('utf-8')
        for si in re.findall(r'<si>(.*?)</si>', ss, re.S):
            shared.append(''.join(re.findall(r'<t[^>]*>(.*?)</t>', si, re.S)))
    wb = z.read('xl/workbook.xml').decode('utf-8')
    rels = z.read('xl/_rels/workbook.xml.rels').decode('utf-8')
    relmap = dict(re.findall(r'<Relationship[^>]*Id="([^"]+)"[^>]*Target="([^"]+)"', rels))
    relmap.update({t: r for r, t in
                   re.findall(r'<Relationship[^>]*Target="([^"]+)"[^>]*Id="([^"]+)"', rels)})
    out = []
    for name, rid in re.findall(r'<sheet[^>]*name="([^"]+)"[^>]*r:id="([^"]+)"', wb):
        tgt = relmap.get(rid, '')
        tgt = tgt if tgt.startswith('xl/') else 'xl/' + tgt.lstrip('/')
        data = z.read(tgt).decode('utf-8')
        rows = {}
        for rnum, rbody in re.findall(r'<row[^>]*r="(\d+)"[^>]*>(.*?)</row>', data, re.S):
            cells = {}
            for ref, _cn, attrs, body in re.findall(
                    r'<c r="([A-Z]+)(\d+)"([^>]*)>(.*?)</c>', rbody, re.S):
                t = re.search(r't="([^"]+)"', attrs)
                v = re.search(r'<v>(.*?)</v>', body)
                isv = re.findall(r'<t[^>]*>(.*?)</t>', body, re.S)
                if t and t.group(1) == 's' and v:
                    val = shared[int(v.group(1))]
                elif isv:
                    val = ''.join(isv)
                elif v:
                    val = v.group(1)
                else:
                    val = ''
                cells[ref] = val
            rows[int(rnum)] = cells
        out.append((name, rows))
    return out


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()

# ---------------------------------------------------------------- 组织 ----

def build_orgs(dept_rows, report):
    """部门表 → 111 个组织节点。node_key = 源表名称（已验证全表唯一）。
    node_type 判定：无上级=ROOT；上级=ROOT 且名含「分公司」=COMPANY；
    其余按名称是否以「项目经理部」结尾分为 PROJECT_DEPT / DEPARTMENT。"""
    orgs = OrderedDict()          # name -> org dict（源表顺序）
    order = []
    for rn in sorted(dept_rows):
        if rn == 1:
            continue
        c = dept_rows[rn]
        name = (c.get('A') or '').strip()
        parent = (c.get('C') or '').strip()
        manager_name = (c.get('B') or '').strip()
        if not name:
            report['errors'].append({'file': FILE_DEPT, 'row': rn, 'issue': '部门名称为空'})
            continue
        if name in orgs:
            report['errors'].append({'file': FILE_DEPT, 'row': rn,
                                     'issue': f'部门名称重复: {name}'})
            continue
        orgs[name] = {'source_row': rn, 'name': name, 'parent_name': parent,
                      'manager_name': manager_name, 'manager_username': None,
                      'manager_status': 'PENDING', 'manager_candidates': []}
        order.append(name)

    # 上级引用完整性 + 层级（用于 node_type 判定）
    roots = [n for n, o in orgs.items() if not o['parent_name']]
    for n, o in orgs.items():
        if o['parent_name'] and o['parent_name'] not in orgs:
            report['errors'].append({'file': FILE_DEPT, 'row': o['source_row'],
                                     'issue': f'上级部门不存在: {o["parent_name"]}'})

    def depth(name, seen=None):
        seen = seen or set()
        o = orgs[name]
        if not o['parent_name']:
            return 1
        if name in seen:
            raise SystemExit(f'组织树存在环: {name}')
        seen.add(name)
        return 1 + depth(o['parent_name'], seen)

    for n, o in orgs.items():
        if not o['parent_name']:
            o['node_type'] = 'ROOT'
        else:
            parent_is_root = orgs[o['parent_name']]['node_type'] == 'ROOT'
            if parent_is_root and n.endswith('分公司'):
                o['node_type'] = 'COMPANY'
            elif n.endswith('项目经理部'):
                o['node_type'] = 'PROJECT_DEPT'
            else:
                o['node_type'] = 'DEPARTMENT'
        o['level'] = depth(n)

    # 子树索引（负责人回填用）：node -> 所有后代节点名集合（含自身）
    children = {n: [] for n in orgs}
    for n, o in orgs.items():
        if o['parent_name']:
            children[o['parent_name']].append(n)
    subtree = {}
    def collect(n):
        s = {n}
        for ch in children[n]:
            s |= collect(ch)
        subtree[n] = s
        return s
    for n in orgs:
        collect(n)

    # node_key 唯一性最终校验（node_key 即源名称）
    if len(set(orgs)) != len(orgs):
        raise SystemExit('node_key 冲突，终止')
    report['org'] = {'total': len(orgs), 'roots': len(roots),
                     'by_type': _count_by(orgs, 'node_type')}
    return orgs, subtree

# ---------------------------------------------------------------- 员工 ----

def norm_username(raw):
    """§7.2.1：字符串读取、保留前导零、去首尾空白、统一大写、不转数字。"""
    return (raw or '').strip().upper()


def build_employees(emp_rows, orgs, subtree, report):
    """员工表 → 10000 条员工。组织匹配规则（§7.2.2，已对真实数据验证 100% 命中）：
      1) 部门字段 == 分公司字段 → 本级员工，company=dept=该 COMPANY 节点
      2) 分公司 == 总公司 → company=ROOT 节点，dept=总公司直属二级部门（按名）
      3) 其它 → company=COMPANY 节点，dept=「分公司-部门」三级节点"""
    users = []
    seen = {}
    dup = []
    unmatched = []
    for rn in sorted(emp_rows):
        if rn == 1:
            continue
        c = emp_rows[rn]
        uname = norm_username(c.get('B', ''))
        if not uname:
            report['errors'].append({'file': FILE_EMP, 'row': rn, 'issue': '工号缺失'})
            continue
        if uname in seen:
            dup.append({'row': rn, 'username': uname, 'first_row': seen[uname]})
            continue
        seen[uname] = rn
        comp = (c.get('C') or '').strip()
        dept = (c.get('D') or '').strip()
        if comp == dept and comp in orgs and orgs[comp]['node_type'] == 'COMPANY':
            company, dept_node = comp, comp           # 规则 1：本级员工
        elif comp == '总公司' and dept in orgs:
            company, dept_node = '总公司', dept        # 规则 2：直属二级部门
        elif comp in orgs and orgs[comp]['node_type'] == 'COMPANY' and f'{comp}-{dept}' in orgs:
            company, dept_node = comp, f'{comp}-{dept}'  # 规则 3：三级部门
        else:
            unmatched.append({'row': rn, 'username': uname, 'company': comp, 'dept': dept})
            continue
        users.append({
            'source_row': rn, 'username': uname,
            'real_name': (c.get('A') or '').strip(),
            'company_node': company, 'dept_node': dept_node,
            'position_name': (c.get('E') or '').strip(),
            # 电话不落任何清单（§7.5：清单不携带电话明文）；phone_cipher 由
            # 部署侧用 AES-256-GCM 密钥另行加密，baseline SQL 中置 NULL。
        })
    report['employee'] = {
        'total_source_rows': len(emp_rows) - 1,
        'accepted': len(users),
        'duplicate_username': dup,
        'org_unmatched': unmatched,
    }
    return users

# ---------------------------------------------------------------- 负责人 ----

def fill_managers(orgs, subtree, users, report):
    """§7.2.3：负责人仅按姓名生成候选，唯一候选才回填。
    候选范围 = real_name 相同 且 员工 dept 节点 ∈ 目标节点子树。
    0 个或多个候选 → manager 留空并进入待确认清单。"""
    by_name = {}
    for u in users:
        by_name.setdefault(u['real_name'], []).append(u)
    pending = []
    filled = 0
    for name, o in orgs.items():
        mname = o['manager_name']
        if not mname:
            continue
        cands = [u for u in by_name.get(mname, [])
                 if u['dept_node'] in subtree[name]]
        o['manager_candidates'] = [{'username': u['username'],
                                    'dept': u['dept_node'],
                                    'position': u['position_name']} for u in cands]
        if len(cands) == 1:
            o['manager_username'] = cands[0]['username']
            o['manager_status'] = 'CONFIRMED_BY_UNIQUE_MATCH'
            filled += 1
        elif len(cands) == 0:
            o['manager_status'] = 'PENDING_NO_CANDIDATE'
            pending.append({'node': name, 'manager_name': mname, 'reason': '无候选'})
        else:
            o['manager_status'] = 'PENDING_MULTIPLE_CANDIDATES'
            pending.append({'node': name, 'manager_name': mname,
                            'reason': '多个候选', 'candidates': o['manager_candidates']})
    report['org']['manager_filled'] = filled
    report['org']['manager_pending'] = pending
    return pending

# ---------------------------------------------------------------- 权限 ----

class CodeMaps:
    """稳定编码映射（幂等核心）：已有 output/code-mappings.json 时复用旧编码，
    新对象按「首个未占用序号」追加（§7.4：不因行序改变编码）。"""

    def __init__(self, out_dir):
        self.path = os.path.join(out_dir, 'code-mappings.json')
        self.data = {'version': MAPPING_VERSION, 'apps': {}, 'modules': {},
                     'functions': {}, 'actions': {}, 'orgs': {}}
        if os.path.exists(self.path):
            with open(self.path, encoding='utf-8') as f:
                self.data = json.load(f)

    def _next_key(self, prefix, existing):
        i = 1
        while f'{prefix}{i:02d}' in existing:
            i += 1
        return f'{prefix}{i:02d}'

    def app_key(self, app_name):
        m = self.data['apps']
        if app_name not in m:
            m[app_name] = self._next_key('app', {v for v in m.values()})
        return m[app_name]

    def module_key(self, app_name, module_name):
        m = self.data['modules'].setdefault(app_name, {})
        if module_name not in m:
            used = set(m.values())
            i = 1
            while f'm{i:02d}' in used:
                i += 1
            m[module_name] = f'm{i:02d}'
        return m[module_name]

    def function_key(self, app_name, module_name, func_name):
        m = self.data['functions'].setdefault(app_name, {})
        key = f'{module_name}|{func_name}'
        if key not in m:
            used = set(m.values())
            i = 1
            while f'f{i:03d}' in used:
                i += 1
            m[key] = f'f{i:03d}'
        return m[key]

    def action_code(self, act_cn, report):
        m = self.data['actions']
        if act_cn not in m:
            if act_cn not in ACTION_MAP:
                report['errors'].append({'issue': f'未知动作，校验失败: {act_cn}'})
                return None
            m[act_cn] = ACTION_MAP[act_cn]
        return m[act_cn]

    def save(self):
        with open(self.path, 'w', encoding='utf-8') as f:
            json.dump(self.data, f, ensure_ascii=False, indent=2, sort_keys=True)


def build_permissions(perm_rows, maps, report):
    """权限清单 → 应用/模块/功能点/原子权限/435 格授权。
    状态口径（§7.4 表格，保守优先——宁可多确认、不乱授权）：
      无               → NONE            不生成关系
      查看本人/查看本部门 → view + DEFERRED_SCOPE
      查看（无范围标注）  → view → PUBLISHED
      其它动作          → PENDING_CONFIRMATION（范围未标，需人工确认）
      全部权限          → 展开该功能点当次已确认的动作全集（逐动作按上述规则定状态，
                          不变通配符；展开集随 code-mappings 版本固定）"""
    rows = [perm_rows[r] for r in sorted(perm_rows) if r != 1]
    apps = OrderedDict(); modules = {}; functions = {}; perms = OrderedDict()
    grants = []; stats = {'cells': 0, 'NONE': 0, 'PUBLISHED': 0, 'DEFERRED_SCOPE': 0,
                          'PENDING_CONFIRMATION': 0, 'MIXED': 0, 'full_expand': 0}
    action_stat = {'view_published': 0, 'view_deferred': 0, 'other_pending': 0}

    # 先收集每个功能点的动作全集（供「全部权限」展开）
    func_actions = {}
    for c in rows:
        app = (c.get('A') or '').strip(); mod = (c.get('B') or '').strip()
        fn = (c.get('C') or '').strip()
        s = set()
        for col, _rk, _rn in ROLE_COLS:
            raw = (c.get(col) or '').strip()
            if raw in ('', '无', '全部权限'):
                continue
            for a in re.split(r'[、,，/;；\s]+', raw):
                a = a.strip()
                if a:
                    s.add(a)
        func_actions[(app, mod, fn)] = s

    for c in rows:
        app = (c.get('A') or '').strip(); mod = (c.get('B') or '').strip()
        fn = (c.get('C') or '').strip(); desc = (c.get('D') or '').strip()
        src_row = c.get('_src_row')
        ak = maps.app_key(app); mk = maps.module_key(app, mod); fk = maps.function_key(app, mod, fn)
        for col, rk, rn_cn in ROLE_COLS:
            raw = (c.get(col) or '').strip()
            if raw == '':
                continue
            stats['cells'] += 1
            detail = []; status_set = set(); perm_keys = []; published_keys = []
            if raw == '无':
                stats['NONE'] += 1
                status_set.add('NONE')
                detail.append('RULE_NONE:不生成关系')
            else:
                acts = (sorted(func_actions[(app, mod, fn)])
                        if raw == '全部权限' else
                        [a.strip() for a in re.split(r'[、,，/;；\s]+', raw) if a.strip()])
                if raw == '全部权限':
                    stats['full_expand'] += 1
                for a in acts:
                    # 范围词特判必须在动作码解析之前：它们不在动作字典里，
                    # 统一解析为 view，但登记为 DEFERRED_SCOPE（§7.4）
                    if a in ('查看本人', '查看本部门'):
                        code = 'view'
                    else:
                        code = maps.action_code(a, report)
                        if code is None:
                            continue
                    pk = f'{ak}:{mk}:{fk}:{code}'
                    perm_keys.append(pk)
                    perm = (ak, mk, fk, code)
                    if perm not in perms:
                        perms[perm] = {'perm_key': pk, 'app_key': ak, 'app_name': app,
                                       'module_key': mk, 'module_name': mod,
                                       'func_key': fk, 'func_name': fn,
                                       'action_code': code, 'action_cn': a,
                                       'source_row': src_row,
                                       'resource_name': fn, 'description': desc}
                    if a in ('查看本人', '查看本部门'):
                        st = 'DEFERRED_SCOPE'
                        detail.append(f'{a}→view@DEFERRED_SCOPE:RULE_SCOPE_DEFERRED')
                    elif code == 'view':
                        st = 'PUBLISHED'
                        detail.append(f'{a}→{code}@PUBLISHED:RULE_VIEW_PUBLISHED')
                    else:
                        st = 'PENDING_CONFIRMATION'
                        detail.append(f'{a}→{code}@PENDING_CONFIRMATION:RULE_UNSCOPED_PENDING')
                    status_set.add(st)
                    if st == 'PUBLISHED':
                        action_stat['view_published'] += 1
                        published_keys.append(pk)   # 仅动作级 PUBLISHED 进正式关系表
                    elif st == 'DEFERRED_SCOPE':
                        action_stat['view_deferred'] += 1
                    else:
                        action_stat['other_pending'] += 1
            if status_set <= {'NONE'}:
                summary = 'NONE'
            elif status_set == {'PUBLISHED'}:
                summary = 'PUBLISHED'; stats['PUBLISHED'] += 1
            elif status_set == {'DEFERRED_SCOPE'}:
                summary = 'DEFERRED_SCOPE'; stats['DEFERRED_SCOPE'] += 1
            elif status_set == {'PENDING_CONFIRMATION'}:
                summary = 'PENDING_CONFIRMATION'; stats['PENDING_CONFIRMATION'] += 1
            else:
                summary = 'MIXED'; stats['MIXED'] += 1
            grants.append({'source_row': src_row, 'app_key': ak, 'app_name': app,
                           'module_key': mk, 'module_name': mod, 'func_key': fk,
                           'func_name': fn, 'role_key': rk, 'role_name_cn': rn_cn,
                           'raw_text': raw, 'status': summary,
                           'detail': '; '.join(detail), 'perm_keys': perm_keys,
                           'published_perm_keys': published_keys})

    report['permission'] = {
        'apps': len(maps.data['apps']), 'modules': sum(len(v) for v in maps.data['modules'].values()),
        'functions': sum(len(v) for v in maps.data['functions'].values()),
        'unique_atomic_perms': len(perms), 'grant_cells': stats,
        'actions': action_stat,
    }
    return apps, modules, functions, perms, grants

# ---------------------------------------------------------------- 输出 ----

def esc(s):
    return str(s).replace('\\', '\\\\').replace("'", "''")


# 与 V3 种子的 id 空间约定：V3 固定占用 sys_application 1..2、
# sys_permission 1..25、sys_role 1（platform/engineering 控制面，幂等不变）。
# 业务基线一律从 100 起步；sys_dept / sys_user 种子未占用，仍从 1 起。
BASE_OFFSET = 100


def write_baseline_sql(out_path, orgs, users, perms, grants):
    """基线数据 SQL：显式主键 + 固定顺序，重跑将主键冲突报错（不静默覆盖人工数据）。
    phone_cipher/password_hash 置 NULL（§8.3：初始 PENDING_ACTIVATION 无密码；
    电话由部署侧加密后经接口录入，离线清单与基线 SQL 均不携带明文）。"""
    dept_id = {n: i + 1 for i, n in enumerate(orgs)}
    perm_id = {pk['perm_key']: BASE_OFFSET + i for i, pk in enumerate(perms.values())}
    role_id = {'SYS_ADMIN': BASE_OFFSET + 1, 'COMPANY_LEADER': BASE_OFFSET + 2,
               'DEPT_MANAGER': BASE_OFFSET + 3, 'PROJECT_MANAGER': BASE_OFFSET + 4,
               'EMPLOYEE': BASE_OFFSET + 5}
    user_id = {u['username']: i + 1 for i, u in enumerate(users)}
    L = []
    L.append('-- baseline_data.sql · 由 tools/import/import_excel.py 自动生成')
    L.append(f'-- 生成时间: {datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}  映射版本: {MAPPING_VERSION}')
    L.append('-- ⚠️ 重跑本文件将因主键冲突而失败——这是有意设计（§7.5：不静默覆盖人工授权）。')
    L.append('SET NAMES utf8mb4;')
    L.append('START TRANSACTION;')
    L.append('\n-- ===== 应用（15 个业务应用，id 从 %d 起，避开 V3 种子占用）=====' % BASE_OFFSET)
    seen_app = OrderedDict()
    for pk in perms.values():
        if pk['app_key'] not in seen_app:
            seen_app[pk['app_key']] = pk['app_name']
    for i, (ak, an) in enumerate(seen_app.items(), BASE_OFFSET):
        L.append(f"INSERT INTO sys_application (id, app_name, app_key, status, create_time, update_time, version) "
                 f"VALUES ({i}, '{esc(an)}', '{esc(ak)}', 1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0);")
    L.append('\n-- ===== 原子权限（功能点 × 动作去重后，id 从 %d 起）=====' % BASE_OFFSET)
    for i, pk in enumerate(perms.values(), BASE_OFFSET):
        desc = f", '{esc(pk['description'])}'" if pk['description'] else ', NULL'
        L.append(f"INSERT INTO sys_permission (id, application_id, module_key, module_name, resource_key, "
                 f"resource_name, resource_description, action_code, perm_name, perm_key, source_row, status, "
                 f"create_time, update_time, version) VALUES ({i}, (SELECT id FROM sys_application WHERE app_key='{esc(pk['app_key'])}'), "
                 f"'{esc(pk['module_key'])}', '{esc(pk['module_name'])}', '{esc(pk['func_key'])}', "
                 f"'{esc(pk['resource_name'])}'{desc}, '{esc(pk['action_code'])}', "
                 f"'{esc(pk['func_name'] + '·' + pk['action_cn'])}', '{esc(pk['perm_key'])}', "
                 f"{pk['source_row'] or 'NULL'}, 1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0);")
    L.append('\n-- ===== 五类角色（不建继承边、不按岗位自动分配）=====')
    for rk, rn_cn in [('SYS_ADMIN', '系统管理员'), ('COMPANY_LEADER', '公司领导'),
                      ('DEPT_MANAGER', '部门经理'), ('PROJECT_MANAGER', '项目经理'),
                      ('EMPLOYEE', '普通员工')]:
        L.append(f"INSERT INTO sys_role (id, role_name, role_key, description, status, create_time, update_time, version) "
                 f"VALUES ({role_id[rk]}, '{rn_cn}', '{rk}', NULL, 1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0);")
    L.append('\n-- ===== 已确认的角色权限关系（仅动作级 PUBLISHED；'
             'DEFERRED_SCOPE 与 PENDING_CONFIRMATION 一律不写入正式关系表，§7.4/§7.5）=====')
    rp = []
    for g in grants:
        for pk in g['published_perm_keys']:
            rp.append((role_id[g['role_key']], perm_id[pk]))
    for rid, pid in sorted(set(rp)):
        L.append(f"INSERT INTO sys_role_permission (role_id, permission_id) VALUES ({rid}, {pid});")
    L.append('\n-- ===== 组织（111 节点；按层级拓扑排序插入——源表行序不保证父先于子；'
             '父 id 用会话变量传递，规避 MySQL 1093 同表子查询限制）=====')
    for n in sorted(orgs, key=lambda x: (orgs[x]['level'], orgs[x]['source_row'])):
        o = orgs[n]
        pid = 'NULL' if not o['parent_name'] else f"@pid_{dept_id[o['parent_name']]}"
        if o['parent_name']:
            L.append(f"SET @pid_{dept_id[o['parent_name']]} := "
                     f"(SELECT id FROM sys_dept WHERE node_key='{esc(o['parent_name'])}');")
        L.append(f"INSERT INTO sys_dept (id, dept_name, node_key, parent_id, node_type, manager_user_id, status, create_time, update_time, version) "
                 f"VALUES ({dept_id[n]}, '{esc(o['name'])}', '{esc(n)}', {pid}, '{o['node_type']}', NULL, 1, "
                 f"UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0);")
    L.append('\n-- ===== 员工（10000；PENDING_ACTIVATION、无密码、无角色）=====')
    buf = []
    for i, u in enumerate(users, 1):
        buf.append(f"({i}, '{esc(u['username'])}', '{esc(u['real_name'])}', "
                   f"(SELECT id FROM sys_dept WHERE node_key='{esc(u['company_node'])}'), "
                   f"(SELECT id FROM sys_dept WHERE node_key='{esc(u['dept_node'])}'), "
                   f"'{esc(u['position_name'])}', NULL, 'PENDING_ACTIVATION', 1, 0, NULL, "
                   f"UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0)")
        if len(buf) == 500:
            L.append('INSERT INTO sys_user (id, username, real_name, company_id, dept_id, position_name, '
                     'phone_cipher, status, must_change_password, failed_login_count, locked_until, '
                     'create_time, update_time, version) VALUES\n  ' + ',\n  '.join(buf) + ';')
            buf = []
    if buf:
        L.append('INSERT INTO sys_user (id, username, real_name, company_id, dept_id, position_name, '
                 'phone_cipher, status, must_change_password, failed_login_count, locked_until, '
                 'create_time, update_time, version) VALUES\n  ' + ',\n  '.join(buf) + ';')
    L.append('\n-- ===== 负责人回填（仅唯一匹配确认的）=====')
    for n, o in orgs.items():
        if o['manager_username']:
            L.append(f"UPDATE sys_dept SET manager_user_id=(SELECT id FROM sys_user WHERE username='{esc(o['manager_username'])}') "
                     f"WHERE node_key='{esc(n)}';")
    L.append('COMMIT;')
    with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(L) + '\n')


def _count_by(d, key):
    r = {}
    for v in d.values():
        r[v[key]] = r.get(v[key], 0) + 1
    return r

# ---------------------------------------------------------------- main ----

def main():
    ap = argparse.ArgumentParser(description='RBAC 第一阶段离线数据初始化')
    ap.add_argument('--src-dir', required=True, help='三份源 Excel 所在目录')
    ap.add_argument('--out-dir', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'output'),
                    help='清单输出目录（默认 tools/import/output）')
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    report = {'generated_at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
              'mapping_version': MAPPING_VERSION, 'errors': []}

    def src(name):
        p = os.path.join(args.src_dir, name)
        if not os.path.exists(p):
            raise SystemExit(f'找不到源文件: {p}')
        return p

    print('[1/5] 读取三份源 Excel ...')
    dept_rows = load_xlsx(src(FILE_DEPT))[0][1]
    emp_rows = load_xlsx(src(FILE_EMP))[0][1]
    perm_rows = load_xlsx(src(FILE_PERM))[0][1]
    for rn, c in perm_rows.items():          # 保留源行号供追溯
        c['_src_row'] = rn

    print('[2/5] 构建组织树（111 节点）...')
    orgs, subtree = build_orgs(dept_rows, report)
    print('[3/5] 构建员工（按唯一工号）并匹配组织 ...')
    users = build_employees(emp_rows, orgs, subtree, report)
    pending_mgr = fill_managers(orgs, subtree, users, report)
    print('[4/5] 解析权限清单（435 授权单元格）...')
    maps = CodeMaps(args.out_dir)
    apps, modules, functions, perms, grants = build_permissions(perm_rows, maps, report)

    print('[5/5] 写出 5 份产物 ...')
    manifest = {'mapping_version': MAPPING_VERSION,
                'files': [{'file': n, 'sha256': sha256_file(src(n)),
                           'data_rows': len(r) - 1}
                          for n, r in [(FILE_EMP, emp_rows), (FILE_DEPT, dept_rows),
                                       (FILE_PERM, perm_rows)]]}
    with open(os.path.join(args.out_dir, 'source-manifest.json'), 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    maps.data['orgs'] = {n: {'node_key': n, 'node_type': o['node_type'],
                             'parent': o['parent_name'] or None}
                         for n, o in orgs.items()}
    maps.save()
    with open(os.path.join(args.out_dir, 'grant-mappings.csv'), 'w',
              encoding='utf-8-sig', newline='') as f:
        w = csv.writer(f)
        w.writerow(['source_row', 'app_key', 'app_name', 'module_key', 'module_name',
                    'func_key', 'func_name', 'role_key', 'role_name_cn', 'raw_text',
                    'status', 'action_detail', 'confirm_basis'])
        for g in grants:
            basis = '；'.join(d.split(':', 1)[-1] for d in g['detail'].split('; ') if d) or 'NONE'
            w.writerow([g['source_row'], g['app_key'], g['app_name'], g['module_key'],
                        g['module_name'], g['func_key'], g['func_name'], g['role_key'],
                        g['role_name_cn'], g['raw_text'], g['status'],
                        g['detail'].replace('; ', ' | '), basis])
    report['org_pending_managers'] = pending_mgr
    report['errors'] = report['errors'][:200]
    report['summary'] = {
        'org_total': report['org']['total'], 'employees_accepted': report['employee']['accepted'],
        'unique_perms': report['permission']['unique_atomic_perms'],
        'grant_cells': report['permission']['grant_cells'],
        'error_count': len(report['errors']),
    }
    with open(os.path.join(args.out_dir, 'validation-report.json'), 'w', encoding='utf-8') as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    write_baseline_sql(os.path.join(args.out_dir, 'baseline_data.sql'),
                       orgs, users, perms, grants)

    # ---- 终端摘要 ----
    s = report['summary']
    print('\n================ 导入摘要 ================')
    print(f"组织节点        : {s['org_total']}（类型分布 {report['org']['by_type']}）")
    print(f"负责人已确认    : {report['org']['manager_filled']}，待确认 {len(pending_mgr)}")
    print(f"员工            : {s['employees_accepted']} / {report['employee']['total_source_rows']}"
          f"（重复工号 {len(report['employee']['duplicate_username'])}，"
          f"组织未匹配 {len(report['employee']['org_unmatched'])}）")
    print(f"应用/模块/功能点: {report['permission']['apps']} / {report['permission']['modules']}"
          f" / {report['permission']['functions']}")
    print(f"原子权限(去重)  : {s['unique_perms']}")
    gc = s['grant_cells']
    print(f"授权单元格      : {gc['cells']}（无 {gc['NONE']}，全部权限展开 {gc['full_expand']}，"
          f"PUBLISHED {gc['PUBLISHED']}，DEFERRED_SCOPE {gc['DEFERRED_SCOPE']}，"
          f"PENDING {gc['PENDING_CONFIRMATION']}，MIXED {gc['MIXED']}）")
    print(f"错误数          : {s['error_count']}")
    print(f"输出目录        : {os.path.abspath(args.out_dir)}")
    return 0 if s['error_count'] == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
