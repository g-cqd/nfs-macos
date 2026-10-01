"""Recipes reject unsafe paths, duplicate destinations and ambiguous payloads."""
from copy import deepcopy
from recipes import load_recipe, validate_recipe


for name in ['nfsmw', 'cod4', 'nfs2015']:
    recipe = load_recipe(name)
    assert recipe['gameID'] == name
    validate_recipe(recipe)
    mutations = [lambda r: r.update(launcher='../escape'),
                 lambda r: r.update(gameID='bad/name'),
                 lambda r: r.update(displayName='../outside'),
                 lambda r: r.update(supportsMP='false'),
                 lambda r: r['originalDirectories'].update({'main': [], 'main/child': []}),
                 lambda r: r.update(editions=['bundled', 'import', 'bundled']),
                 lambda r: r.update(editions=[]),
                 lambda r: r.update(runtimeRetention=['../escape'])]
    if recipe['compatibility']:
        mutations += [lambda r: r['compatibility'].append(dict(r['compatibility'][0])),
                      lambda r: r['compatibility'][0].update(path='../outside'),
                      lambda r: r['compatibility'][0].update(path='/absolute')]
    if recipe['originalFiles']:
        mutations.append(lambda r: r['originalFiles'].append(r['originalFiles'][0]))
    for change in mutations:
        altered = deepcopy(recipe)
        change(altered)
        try: validate_recipe(altered)
        except ValueError: pass
        else: raise AssertionError('Invalid recipe was accepted')
print('Recipe validation regressions passed')
