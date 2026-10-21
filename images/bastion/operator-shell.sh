# shellcheck shell=sh
# operator-shell.sh — bastion operator login environment (adapted from the reference bastion).
# Installed to /etc/profile.d/ (login shells) and sourced from /etc/bash.bashrc (interactive).
# KUBECONFIG pinned to the active-cluster symlink; `k` alias + bash completion; lands in /workspace.
[ -n "${_AI_FABRIC_OPERATOR_SHELL:-}" ] && return 0 2>/dev/null
_AI_FABRIC_OPERATOR_SHELL=1
_state="/var/opt/ai-fabric/clusters/current"
export KUBECONFIG="${_state}/kubeconfig.yaml"
case ":${PATH}:" in *":/usr/local/bin:"*) : ;; *) PATH="/usr/local/bin:${PATH}"; export PATH ;; esac
case "$-" in
    *i*)
        if [ ! -e "${_state}" ]; then
            printf 'no active cluster yet: the init master publishes the kubeconfig when bootstrap completes\n' >&2
        fi
        if [ -n "${BASH_VERSION:-}" ] && command -v kubectl >/dev/null 2>&1; then
            alias k='kubectl'
            alias kns='kubectl config set-context --current --namespace'
            eval "$(kubectl completion bash 2>/dev/null)"
            complete -F __start_kubectl k 2>/dev/null
        fi
        cd /workspace 2>/dev/null || true
        ;;
esac
unset _state
