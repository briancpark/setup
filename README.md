# Setup

New computer setup script with my preferences. Designed to run on either macOS or Ubuntu.

This is public so I can pull without setting up GitHub keys. This is not intended for public use.

## Installation

One line installation:

```sh
git clone git@github.com:briancpark/setup.git && cd setup && ./setup.sh
```

### Advanced Installation

There are four levels of installation. Each has special configuration tailored towards a specific use case. However, they all install the essentials needed to make any shell feel like home for me.

```sh
./setup.sh --embedded
./setup.sh --remote
./setup.sh --company
./setup.sh --personal
```

| Flag         | Description |
|--------------|-------------|
| `--embedded` (0) | Just the essentials needed for development on machines like Raspberry Pi and smaller. No unnecessary features or bloat. Simple. |
| `--remote` (1)   | Setup for remote/shared machines, like supercomputers. Should be relatively lightweight to accommodate storage quotas. |
| `--company` (2)  | Setup for work machines. It's still lightweight, but it should include the essentials. One restriction in packages and libraries is that they MUST be MIT open source licensed. If combined with the `--remote` flag, a blacklist is applied. |
| `--personal` (3) | Setup for personal machines. Install all the features and applications you can think of without worrying about storage or performance. |

# TODO List

- [ ] Agnostic setup script
- [ ] Automate oh-my-zsh setup
- [ ] vim setup
- [ ] tmux setup
- [ ] Option to minimize installations (reduce bloat)
- [ ] Company setup option that lies in private repository
