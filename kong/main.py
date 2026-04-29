import os
import asyncio
from anthropic import AsyncAnthropic, DefaultAioHttpClient


async def main() -> None:
    async with AsyncAnthropic(
        api_key=os.environ.get("ANTHROPIC_API_KEY"),
        base_url="http://localhost:8000/anthropic",
    ) as client:
        message = await client.messages.create(
            max_tokens=1024,
            messages=[
                {
                    "role": "user",
                    "content": "300+10",
                }
            ],
            model="claude-opus-4-6",
        )
        print(message.content)


asyncio.run(main())