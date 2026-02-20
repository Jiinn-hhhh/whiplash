#!/usr/bin/env bash
# agent-team/boot.sh — Agent Team 모드 진입점
# Agent Teams 환경변수를 설정하고 Claude Code를 실행한다.
# 이후 온보딩/Manager 동작은 프레임워크 문서가 처리한다.
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
exec claude
