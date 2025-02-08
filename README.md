# Transcription with OpenAI Whisper

## Overview

This Streamlit application allows you to upload MP3 or MP4 files and transcribe their audio content using OpenAI’s Whisper API. It supports:
- **Audio/Video Uploads:** Upload one or more MP3 or MP4 files.
- **MP4 Conversion:** Automatically converts MP4 files to MP3 for transcription.
- **Chunked Transcription:** Splits long audio files into smaller chunks to handle lengthy recordings.
- **Transcript Management:** Toggle transcript visibility and download individual or zipped transcript files.

## Live Demo

Check out the live demo here: [Demo Link](https://rags-demo.streamlit.app/)

## Setup and Installation

Follow these steps to replicate the setup on your local machine:

### Prerequisites

- **Python 3.8+**
- **ffmpeg:** Required by MoviePy and Pydub for audio/video processing.  
  - **Installation on Ubuntu/Debian:**  
    ```bash
    sudo apt-get update
    sudo apt-get install ffmpeg
    ```
  - **Installation on macOS (with Homebrew):**  
    ```bash
    brew install ffmpeg
    ```
  - **Installation on Windows:**  
    Download from the [FFmpeg website](https://ffmpeg.org/download.html) and follow the installation instructions.
- **OpenAI API Key:** Sign up at [OpenAI](https://openai.com/) to obtain your API key.

### Steps

1. **Clone the Repository**

   ```bash
   git clone https://github.com/your-username/transcribe-app.git
   cd transcribe-app
   ```

2. **Create a Virtual Environment**

   ```bash
   python -m venv venv
   source venv/bin/activate  # On Windows, use: venv\Scripts\activate
   ```

3. **Install Required Packages**

   Install the necessary Python packages using pip:

   ```bash
   pip install streamlit moviepy pydub openai
   ```

   *Alternatively, if a `requirements.txt` file is provided, run:*

   ```bash
   pip install -r requirements.txt
   ```

4. **Configure Streamlit Secrets**

   Create a `.streamlit` directory in the project root if it doesn't exist, then create a file named `secrets.toml` inside it:

   ```toml
   # .streamlit/secrets.toml
   OPENAI_API_KEY = "your_openai_api_key_here"
   ```

   Replace `"your_openai_api_key_here"` with your actual OpenAI API key.

5. **Run the Application**

   Start the Streamlit server by running:

   ```bash
   streamlit run app.py
   ```

   This command will launch the application in your default web browser.

## Usage

1. **Upload Files:**  
   Use the file uploader to select one or more MP3 or MP4 files.

2. **Set Filename:**  
   Enter a base filename for the transcript(s). If multiple files are uploaded, the transcripts will be named sequentially (e.g., `transcript_1.txt`, `transcript_2.txt`, etc.).

3. **Transcribe:**  
   Click the **Start Transcribing** button to process the files. The app will convert, split (if needed), and transcribe the files, showing progress indicators during the process.

4. **View and Download:**  
   - Toggle transcript visibility with the **Show/Hide Transcript** button.
   - Download the transcript(s) using the **Download Transcript** button. For multiple files, transcripts will be packaged into a ZIP archive.

## Contributing

Contributions are welcome! If you have suggestions or improvements, feel free to open an issue or submit a pull request.

## License

Distributed under the MIT License. See the [LICENSE](LICENSE) file for more details.

## Acknowledgments

- [OpenAI Whisper](https://openai.com/research/whisper)
- [Streamlit](https://streamlit.io)
- [MoviePy](https://zulko.github.io/moviepy)
- [Pydub](https://github.com/jiaaro/pydub)

Happy transcribing!
