#!/usr/bin/env hython
"""Verify package-only discovery and saved graph conventions in a fresh process.

Run with HOUDINI_PACKAGE_DIR=<repo>/demo/island/packages. No explicit
HDA installation and no live Houdini scene access. Does not cook hero terrain.
"""
import hou, os, sys, re, json
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, 'scripts', 'houdini'))
from hda_source_metadata import builder_source_matches, contract_metadata_matches
repo=os.path.realpath(os.path.join(REPO, 'demo', 'island', 'hda'))
g=hou.node('/obj').createNode('geo','package_probe')
for typename in ('hego_island_erosion::1.0','hego_material_distribution::1.0','hego_terrain_tint::1.0'):
    t=hou.nodeType(hou.sopNodeTypeCategory(),typename)
    assert t is not None, typename+' not package-discovered'
    assert os.path.realpath(t.definition().libraryFilePath()).startswith(repo), t.definition().libraryFilePath()
    n=g.createNode(typename)
    assert n.matchesCurrentDefinition()
    assert not [c.path() for c in n.allSubChildren() if c.type().definition() and not c.matchesCurrentDefinition()]
    n.allSubChildren(sync_delayed_definition=True)
    boxes=n.networkBoxes();assert boxes and all(b.autoFit() for b in boxes)
    children=n.children();low=min(x.position().y() for x in children)
    assert all(x.position().y()==low for x in children if x.type().name()=='output')
    for x in children:
        for c in x.inputConnections():
            assert c.inputNode() is None or c.inputNode().position().y()>x.position().y(), (x.path(),c.inputNode().path())
        if x.type().name()=='object_merge':
            p=x.parm('objpath1').evalAsString();assert p.startswith('../') and x.node(p)
            assert x.node(p).position().y()>x.position().y()
        if x.type().name().split('::')[0] in ('attribwrangle','volumewrangle'):
            assert tuple(x.color().rgb())==tuple(hou.Color((.32,.7,.38)).rgb())
    sections = t.definition().sections()
    stem = typename.split('::')[0]
    builder_file = {'hego_island_erosion': 'build_island_hda.py',
                    'hego_material_distribution': 'build_material_distribution_hda.py',
                    'hego_terrain_tint': 'build_tint_hda.py'}[stem]
    contract_file = {'hego_island_erosion': 'contract.json',
                     'hego_material_distribution': 'material_contract.json',
                     'hego_terrain_tint': 'tint_contract.json'}[stem]
    assert builder_source_matches(sections['hego_' + builder_file].contents(), open(os.path.join(REPO, 'scripts', 'houdini', builder_file)).read())
    assert contract_metadata_matches(sections['hego_contract.json'].contents(), open(os.path.join(repo, contract_file)).read())
    if 'hego_graph_layout.py' in sections:
        assert sections['hego_graph_layout.py'].contents() == open(os.path.join(REPO, 'scripts', 'houdini', 'graph_layout.py')).read()
    help=sections['Help'].contents()
    names=[]
    def walk(items):
        for p in items:
            assert not p.help()
            if isinstance(p,hou.FolderParmTemplate):walk(p.parmTemplates())
            else:names.append(p.name())
    walk(t.definition().parmTemplateGroup().parmTemplates())
    assert all('#id: '+p in help for p in names)
    print('PASS package discovery + native graph + matching nested HDAs + help:',typename,len(children),'nodes',len(names),'parameters',flush=True)
# Independent interfaces; no scene globals or skipped parent scope.
a=g.createNode('hego_island_erosion::1.0');b=g.createNode('hego_island_erosion::1.0')
a.allSubChildren(sync_delayed_definition=True);b.allSubChildren(sync_delayed_definition=True)
a.parm('material_seed').set(41);b.parm('material_seed').set(53)
assert a.node('material_stage').parm('seed').eval()==41 and b.node('material_stage').parm('seed').eval()==53
assert a.node('heightfield_erode1').parm('weathering').expression().find('../thermal_scale')>=0
print('PASS fresh independent local interfaces',flush=True)
print('PASS embedded current layout, contracts and builder provenance (demo path migration allowed)',flush=True)
print('[done] package-only validation passed',flush=True)
