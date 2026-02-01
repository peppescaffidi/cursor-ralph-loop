# Ralph Wiggum – Loop autonomo per Cursor

Libreria riutilizzabile per far girare **Ralph** (agente autonomo basato su [cursor-agent](https://cursor.com)) nel tuo progetto: esegue User Story da un PRD in JSON, con rotazione del contesto, retry e opzioni per branch/PR e modalità parallela.

---

## 1. Scopo del progetto

Implementare il **Ralph Loop** pensato come in **Claude Code** (un agente per feature, PRD come fonte, progresso in file e git), ma **dentro Cursor**: uso di `cursor-agent`, stream-parser, guardrails e loop gestiti da script bash, con la fonte di lavoro che diventa un PRD generato dalle Claude/Cursor skills invece di un file di task a checkbox.

In sintesi: stesso *modello mentale* di Ralph in Claude Code (PRD → una US per run → segnale di completamento → stato in file), portato nell’ecosistema Cursor con le skill per creare il PRD e con l’architettura (parser, retry, parallelo) già sviluppata per Cursor.

---

## 2. Fonti di origine

Questo progetto unisce tre riferimenti:

| Fonte | Ruolo |
|-------|--------|
| **Ralph originale** | Tecnica di [Geoffrey Huntley](https://ghuntley.com/ralph/): loop autonomo, stato in file e git, rotazione del contesto invece di “memory” nell’LLM. |
| **Ralph per Claude Code** | [simone-rizzo/ralph-wiggum-claude-code-](https://github.com/simone-rizzo/ralph-wiggum-claude-code-): Ralph con **PRD** (`prd.json`) e “una feature per run”; dove dal file **`ralph.sh`** deriva la logica docker sandbox, `@prd.json` e `@progress.txt`, “work on single feature”, `<promise>COMPLETE</promise>`. |
| **Ralph per Cursor** | [agrimsingh/ralph-wiggum-cursor](https://github.com/agrimsingh/ralph-wiggum-cursor): implementazione Cursor CLI (cursor-agent, stream-parser, token tracking, guardrails, retry, parallel, once). Fonte di lavoro: **`RALPH_TASK.md`** (checkbox `[ ]` / `[x]`), rotazione a 80k token. |

Da **Simone Rizzo** viene l’idea di usare un PRD generato dalle skill (PRD → prd.json) e un agente che lavora su una singola feature/US. Da **Agrim Singh** viene l’infrastruttura Cursor (script, parser, UI, parallelo, once, guardrails).

---

## 3. Cosa ho fatto: unione skills + Cursor con due varianti

Ho unito ciò che fanno le **Claude/Cursor skills** con ciò che aveva già fatto **Agrim Singh** in ralph-wiggum-cursor, aggiungendo due varianti principali.

### 3.1. File di origine: PRD generato da skill PRD e poi skill Ralph

- **Fonte lavoro** non è più `RALPH_TASK.md` (checkbox), ma **`ralph/prd.json`** (User Stories con `id`, `title`, `acceptanceCriteria`, `priority`, `passes`).
- **Creazione del PRD** (come in [ralph-wiggum-claude-code-](https://github.com/simone-rizzo/ralph-wiggum-claude-code-)):
  1. **Skill PRD** (`.claude/skills/prd`): l’utente chiede di creare un PRD; la skill fa domande chiarificatrici e scrive `tasks/prd-[feature].md`.
  2. **Skill Ralph** (`.claude/skills/ralph`): l’utente passa quel file e chiede di convertirlo in formato Ralph; la skill crea **`ralph/prd.json`**.
- **Completamento**: tutte le User Story con `passes: true` (invece di “tutte le checkbox `[x]`”).
- **Segnale fine US**: l’agente non modifica il JSON; emette **`<ralph>US-DONE US-XXX</ralph>`** e uno script aggiorna `prd.json` con `jq` (evita JSON malformato).
- **Progresso**: `progress.txt` in root (append da ogni agente) + campo `passes` in `prd.json`.

Flusso init: `init-ralph.sh` crea `tasks/` e `progress.txt`, non un template `prd.json`; le due skill si usano in Cursor per generare prima il PRD in markdown e poi `ralph/prd.json`.

### 3.2. Contesto ripulito ad ogni US (con idee prese da Agrim Singh)

- **Un agente per User Story**: ogni run è dedicata a **una sola US**; nessun `--resume`, sempre contesto nuovo.
- **ROTATE a 80k token** (mantenuta): se una singola US supera la soglia di contesto, si fa **retry della stessa US** con un nuovo agente (contesto pulito), invece di cambiare US.
- **Retry per US**: `MAX_ITERATIONS` = max run **per singola US** (es. 3 tentativi per US), non un max globale.
- **Guardrails, once, parallel, stream-parser**: conservati dall’implementazione di Agrim Singh (guardrails.md, ralph-once.sh, ralph-parallel.sh, token tracking, DEFER/GUTTER, ecc.); adattati al modello “fonte = prd.json” e “prossimo lavoro = prossima US incompleta”.

In sintesi: contesto **ripulito a ogni US** (una run = una US), ma con le “safety” e gli strumenti già presenti in ralph-wiggum-cursor (80k → retry stessa US, retry con backoff, parallel, once, guardrails).

---

## Confronto rapido

| Aspetto | ralph-wiggum-cursor (Agrim) | Questa variante (cursor-ralph-loop) |
|--------|-----------------------------|-------------------------------------|
| **Fonte lavoro** | `RALPH_TASK.md` (checkbox) | `ralph/prd.json` (User Stories) |
| **Come si crea** | Edit manuale | Skill PRD → `tasks/prd-*.md` → Skill Ralph → `ralph/prd.json` |
| **Completamento** | Tutte le `[ ]` → `[x]` | Tutte le US con `passes: true` |
| **Segnale fine US** | (N/A) | `<ralph>US-DONE US-XXX</ralph>`; script aggiorna prd con jq |
| **Rotazione** | Nuovo agente a 80k token | Un agente per US; ROTATE = retry stessa US con contesto pulito |
| **Progresso** | `progress.md` + checkbox | `progress.txt` (append) + `prd.json` (passes) |

---

## Requisiti

- **Bash** (macOS/Linux)
- **Git** (repository nel progetto)
- **jq** – per leggere/aggiornare `ralph/prd.json` → `brew install jq` (macOS) o il tuo package manager
- **cursor-agent** – CLI Cursor → `curl https://cursor.com/install -fsS | bash`
- **gum** (opzionale, per UI interattiva) → `brew install gum`

---

## Installazione nel tuo progetto

### Opzione A: Submodule Git

```bash
cd /path/to/tuo-progetto
git submodule add https://github.com/TUO-USER/cursor-ralph-loop.git ralph
./ralph/init-ralph.sh
```

### Opzione B: Copia della cartella

```bash
cd /path/to/tuo-progetto
git clone https://github.com/TUO-USER/cursor-ralph-loop.git .ralph-repo
cp -R .ralph-repo/ralph ./ralph
./ralph/init-ralph.sh
# opzionale: rm -rf .ralph-repo
```

`init-ralph.sh` crea: `.ralph/`, `tasks/`, `progress.txt`, e aggiorna `.gitignore`; opzionalmente copia gli script in `.cursor/ralph-scripts/`.

---

## Uso

### 1. Avere un `ralph/prd.json`

**Con le Cursor skills (consigliato):**

1. **Skill PRD** – “crea un PRD per [feature]” → la skill scrive `tasks/prd-my-feature.md`.
2. **Skill Ralph** – con quel file: “converti questo PRD in formato Ralph” / “crea prd.json da questo” → crea/aggiorna `ralph/prd.json`.

**A mano:** crea `ralph/prd.json` con `project`, `description`, `userStories[]` (per ogni US: `id`, `title`, `description`, `acceptanceCriteria[]`, `priority`, `passes`, `notes`).

### 2. Eseguire il loop

```bash
./ralph/ralph-setup.sh                    # interattivo (modello, opzioni, branch, PR)
./ralph/ralph-loop.sh                     # CLI
./ralph/ralph-loop.sh -n 50 -m opus-4.5-thinking
./ralph/ralph-loop.sh --branch feature/api --pr -y
./ralph/ralph-loop.sh --parallel --max-parallel 4
./ralph/ralph-once.sh                     # una sola US (test)
./ralph/ralph-loop.sh -h
```

---

## File principali nella cartella `ralph/`

| File | Uso |
|------|-----|
| `init-ralph.sh` | Inizializza progetto (`.ralph/`, `tasks/`, `progress.txt`, script in `.cursor/ralph-scripts/`) |
| `ralph-setup.sh` | Entry point interattivo (modello, opzioni, loop) |
| `ralph-loop.sh` | Loop da CLI (iterazioni, modello, branch, PR, parallelo) |
| `ralph-once.sh` | Una sola User Story poi stop |
| `ralph-common.sh` | Funzioni condivise (PRD, prompt, run iterazione, prerequisiti) |
| `ralph-retry.sh` | Retry con backoff |
| `ralph-parallel.sh` | Esecuzione parallela con worktree |
| `ralph.sh` | Script originale stile Claude Code (docker sandbox, prd.json + progress.txt) |
| `task-parser.sh` | Parser task/YAML (opzionale) |
| `stream-parser.sh` | Parsing output stream-json di cursor-agent |

---

## Cartella `.ralph/` (stato)

Creata da `init-ralph.sh` **nel progetto che usa Ralph**. Contiene:

| File | Ruolo |
|------|--------|
| **guardrails.md** | “Segnali” / lezioni dai fallimenti; l’agente li legge e rispetta. |
| **progress.md** | Log sessioni (script): quale US partita/finita, rotazione, gutter. |
| **.iteration** | Contatore usato dalle funzioni di stato. |
| **errors.log** | Errori rilevati (es. stream-parser); l’agente li legge. |
| **activity.log** | Tool call in tempo reale; utile `tail -f .ralph/activity.log`. |

File temporanei (`.current_prompt`, `.parser_fifo`, `agent_raw.log`) sono effimeri e in `.gitignore` dove serve.

---

## Variabili d’ambiente

- **`CURSOR_API_KEY`** – per evitare login quando l’agente gira (es. CI).
- **`RALPH_MODEL`** – modello di default; sovrascrivibile con `-m` in `ralph-loop.sh`.

---

## Riferimenti

- [Ralph (ghuntley.com)](https://ghuntley.com/ralph/) – tecnica originale (Geoffrey Huntley)
- [simone-rizzo/ralph-wiggum-claude-code-](https://github.com/simone-rizzo/ralph-wiggum-claude-code-) – Ralph per Claude Code (PRD, `ralph.sh`)
- [agrimsingh/ralph-wiggum-cursor](https://github.com/agrimsingh/ralph-wiggum-cursor) – Ralph per Cursor CLI (task da `RALPH_TASK.md`)
- [cursor-agent](https://cursor.com) – installazione e uso della CLI
