# How We Taicked OpenCode to Talk to Julia 1

*Explained like you're five*

---

## What is Julia 1?

Julia 1 is a tiny brain (144 million numbers — a real brain has 86 billion!). It doesn't talk or write stories. Instead, you show it some facts and a list of choices, and it picks the best one. Like a robot friend who's really good at multiple-choice questions.

---

## The Big Idea

OpenCode is a coding assistant — it writes and edits files for you. But OpenCode doesn't have a brain for decisions like "which team should handle this email?" That's what Julia 1 is for.

So we connected them! Now you can ask OpenCode something, and OpenCode can ask Julia 1 to make a smart choice.

---

## The Steps We Took (In Baby Steps)

### Step 1: Find a Computer That Can Run Julia 1

Julia 1 needs Python (a programming language) to work. It needs Python version 3.11 or newer.

- We checked the Python version: `Python 3.14.7` — great, that's new enough!
- But there was no `pip` (the thing that installs Python packages), so we made a special room just for Julia 1 called a **virtual environment**.

```bash
python3 -m venv ~/.local/julia-env
```

> **Like:** Imagine you have a toy box that only has Julia 1 toys in it. That way they don't get mixed up with your other toys.

**Why `~/.local/`?** Because it's YOUR special folder that stays even after the computer restarts. We don't use `/tmp` because that's like a chalkboard — it gets erased when you reboot!

---

### Step 2: Download Julia 1's Brain

Julia 1's brain is stored on Hugging Face (a website where people share AI models). The brain file is 550 MiB — about as big as 100 songs!

```bash
pip install huggingface_hub
python -c "from huggingface_hub import snapshot_download; snapshot_download('SupersonicLabs/Julia-1', local_dir='~/.local/share/julia-1')"
```

> **Like:** Downloading a puzzle so you can build it at home. Once it's on your computer, you don't need the internet anymore.

---

### Step 3: Install the Toolbox (PyTorch)

Julia 1 uses a toolbox called **PyTorch** to think. We installed the CPU version (the one that works without a fancy graphics card).

```bash
pip install torch --index-url https://download.pytorch.org/whl/cpu
```

> **Like:** Getting the right screwdriver so you can build the puzzle.

---

### Step 4: Install Julia 1's Instructions

Julia 1 comes with its own little instruction book (a Python package called `supersonic-julia`). We told the computer to read it.

```bash
pip install -e ~/.local/share/julia-1
```

> **Like:** Reading the puzzle instructions before you start building.

---

### Step 5: Build a Translator (The Bridge Script)

OpenCode and Julia 1 speak different languages. We wrote a tiny translator that:
1. Takes a question from OpenCode (in JSON format)
2. Asks Julia 1 to think about it
3. Gives the answer back to OpenCode (in JSON format)

The translator is at:
```
~/.config/opencode/skills/julia-1/scripts/julia_predict.py
```

> **Like:** If you only speak English and your friend only speaks French, you need someone in the middle to translate. That's what this script does.

---

### Step 6: Write a Note for OpenCode (The Skill File)

OpenCode has a special notebook where it keeps track of things it can do. We wrote a note saying:

> "Hey OpenCode! When someone needs to make a choice, classify something, rate something, or answer yes/no — use the Julia 1 translator script!"

The note is at:
```
~/.config/opencode/skills/julia-1/SKILL.md
```

> **Like:** Writing a sticky note that says "If someone asks you to pick ice cream flavors, ask Julia 1 for help!"

---

### Step 7: Test It!

We asked Julia 1 a question to make sure everything works:

> **Customer says:** "I was charged twice for the same order."
> **Question:** Which team should handle this?
> **Choices:** Billing, Shipping, Account access

Julia 1 answered: **Billing** with 85.4% confidence. Correct!

---

## How to Use It Now

Just talk to me (OpenCode) normally. Say things like:

| You say | What happens |
|---|---|
| "Classify this text: 'My login is broken' — options: billing, shipping, tech support" | OpenCode asks Julia 1, which picks the best option |
| "Rate this email: low / medium / high urgency" | Julia 1 picks where it falls on the scale |
| "Is this a refund request? yes or no" | Julia 1 says yes or no with a confidence score |
| "Should I apologize to this customer? yes or no" | Julia 1 gives a probability |

OpenCode will automatically use Julia 1 whenever it makes sense. You don't need to do anything special!

---

## Where Everything Lives

```
Your Computer
├── ~/.local/share/julia-1/              <- Julia 1's brain (550 MiB)
│   ├── config.json
│   ├── model.safetensors               <- The actual weights
│   └── julia/                          <- Julia 1's Python code
│
├── ~/.local/julia-env/                 <- Special Python room (virtual environment)
│
└── ~/.config/opencode/skills/julia-1/  <- The sticky note for OpenCode
    ├── SKILL.md                        <- Instructions for OpenCode
    └── scripts/
        └── julia_predict.py            <- The translator
```

All under `~/.local/` and `~/.config/` — your personal folders that survive reboots!

---

## Important Things to Remember

1. **It works offline!** Once everything is downloaded, no internet needed.
2. **It runs on your CPU.** No expensive graphics card required.
3. **It's fast.** About 300 milliseconds per decision on a regular laptop.
4. **It can only pick from options YOU give it.** It can't make up new answers.
5. **2 to 20 options max** per question. No more than 20!
6. **Everything is in `~/.local/`** — safe from reboots!

---

## If Something Breaks

| Problem | Fix |
|---------|-----|
| "julia not found" | Run: `source ~/.local/julia-env/bin/activate` first |
| Model won't load | Check that `~/.local/share/julia-1/model.safetensors` exists |
| Wrong answer | Try rephrasing your question or giving clearer options |
| Slow first call | Normal! The brain needs to wake up (~10 seconds). After that it's fast. |
| After a reboot | Everything still works! Just use `~/.local/` paths instead of `/tmp/` |

---

*That's it! OpenCode and Julia 1 are now best friends, and they'll stay friends even after you turn your computer off and on again.*
