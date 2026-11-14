# SaveTinker Zelda editors

| Editor | Game |
|---|---|
| `oot-switch2` | The Legend of Zelda: Ocarina of Time (Switch 2) |

The Ocarina of Time editor covers the player, items, songs, dungeons, story steps, chests, Gold Skulltulas, the spawn
point and every named flag, and browses dialogue and actor data from the installed game. Flag names come from the
reverse engineering in `data/flags.json`.

## Adding the repository in SaveTinker

Repositories tab, *Add repository*, then:

```
https://raw.githubusercontent.com/mrissaoussama/savetinker-zelda/main/repo/repo.json
```

The repository must be public for the console to download it.

## Updating

```sh
savetinker-cli validate editors/*
savetinker-cli pack editors repo --name "SaveTinker Zelda editors" --maintainer mrissaoussama
```
