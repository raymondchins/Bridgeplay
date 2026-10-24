# Bridgeplay is discontinued

I'm sorry.

I built Bridgeplay as a fork of [NotProton](https://github.com/NotProtonNot/NotProton) so it would
run on engines other than CrossOver. NotProton's maintainer had said many times, in public, that
they did not want that. The GPL let me make the fork. That did not make it the right thing to do,
and I put my own idea of what was allowed ahead of what they had asked for.

I also leaned on AI assistance heavily and told people the result was well tested. The maintainer
said that kind of development reflects poorly on their project, and they were right to be
concerned about something that touches the Steam client. I also presented a 32-bit game bug as a
NotProton problem when it was a bug in my own code. I should not have done that.

The core of it is that Wine on the Mac exists because of CodeWeavers. They are the largest
contributor to Wine, and CrossOver licence sales are what pay for that work. A free tool that
steers people away from CrossOver takes money from the people who make Mac gaming possible. I
should have understood that before publishing, not after.

## What was said

This started with NotProton issue #79, "This should not exist". I'm showing it so you can read
their words, not only my summary.

![NotProton issue #79, "This should not exist"](screenshots/1-issue-79-this-should-not-exist.png)

![The maintainer on CodeWeavers and the Wine Project](screenshots/2-codeweavers-and-wine.png)

I answered the maintainer and said I would not delete the project. I was wrong to.

![My earlier reply, which I now withdraw](screenshots/3-my-reply.png)

The reply to it ran my answer through an AI detector and told me to delete the repo.

![An AI detector result on my reply, with a request to delete the repo](screenshots/4-ai-detector-response.png)

## What I've done

- Stopped development. The code has been removed from this repository.
- I won't distribute Bridgeplay or builds of it anymore.
- I won't send PRs or issues to NotProton about Bridgeplay.

## Please support CodeWeavers

If you want to play Windows games on your Mac, buy [CrossOver](https://www.codeweavers.com/crossover)
and use [NotProton](https://github.com/NotProtonNot/NotProton) with it. That is the supported way,
and it pays for the work all of us depend on.

- CrossOver: <https://www.codeweavers.com/crossover>
- NotProton: <https://github.com/NotProtonNot/NotProton>
- The Wine Project: <https://www.winehq.org>

Thank you to CodeWeavers and to NotProton's maintainer. I'm sorry for the harm and the noise.

The GPL-3.0 licence text is kept in [LICENSE](LICENSE).

---

*How this was written: the wording of this apology was drafted with Claude Sonnet 5.5 on 24 October 2026, at the request of
Rahmat Wibowo, so that it would be clear and honest. The decision to stop the project is his. You can
reach him on [LinkedIn](https://www.linkedin.com/in/rahmatwi/).*
