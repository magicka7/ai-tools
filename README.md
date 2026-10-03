# ai-tools

/pr-cross-check.sh sends a PR's diff to two LLMs (GPT and DeepSeek, through the ppq.ai API) and prints their reviews so you can compare them. To set it up, copy .review.env_example to .review.env and add your ppq.ai API key. Then run the script from inside the repo. Never commit .review.env.