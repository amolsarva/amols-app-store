# Draft announcement: Python Guard

_Status: draft. Edit, then post (LinkedIn / X / newsletter). Delete this line when posted._

**🐍 New in Amol's App Store: Python Guard**

Keeps Python working on your Mac through every Homebrew upgrade: installs the matching Tk, rebuilds tool environments for the new version, and heals itself the moment Homebrew changes Python.

Every Homebrew Python upgrade quietly breaks something: Tk apps stop opening, private environments point at a Python that no longer exists, and `pip install` is refused outright. Python Guard is the one place every tool in this collection asks for Python. It finds the best interpreter, installs `python-tk` for whatever version Homebrew just switched to, rebuilds each tool's private environment on the new version, and runs again automatically whenever Homebrew relinks python3.

Free, open, runs on your own Mac. Get it: https://amolsarva.com/scripts · Source: https://github.com/amolsarva/amols-app-store/tree/main/python-guard

#mac #opensource #tools
