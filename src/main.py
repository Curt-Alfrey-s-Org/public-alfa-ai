import sys
from src.agent.loop import run_agent


def main() -> None:
    if len(sys.argv) >= 2:
        message = " ".join(sys.argv[1:])
        result = run_agent(message)
        print(result.text)
        return

    print("ALFa AI interactive mode. Type 'exit' to quit.")
    while True:
        try:
            message = input("> ").strip()
        except EOFError:
            break
        if not message:
            continue
        if message.lower() in {"exit", "quit"}:
            break
        result = run_agent(message)
        print(result.text)


if __name__ == "__main__":
    main()
