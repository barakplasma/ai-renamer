package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const maxText = 1 << 20
const maxImage = 20 << 20

var client = &http.Client{
	Timeout:       120 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

func request(base, route, key string, payload any, out any) error {
	base = strings.TrimRight(base, "/")
	if strings.HasSuffix(base, "/v1") && strings.HasPrefix(route, "/v1/") {
		route = route[3:]
	}
	endpoint, err := url.Parse(base + route)
	if err != nil || (endpoint.Scheme != "http" && endpoint.Scheme != "https") ||
		endpoint.Host == "" || endpoint.User != nil {
		return errors.New("base URL must be an HTTP or HTTPS endpoint without credentials")
	}
	var input io.Reader
	method := http.MethodGet
	if payload != nil {
		body, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		input, method = bytes.NewReader(body), http.MethodPost
	}
	req, err := http.NewRequest(method, endpoint.String(), input)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, maxText+1))
	if err != nil {
		return err
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		var detail struct{ Error json.RawMessage }
		var message string
		if json.Unmarshal(raw, &detail) == nil && json.Unmarshal(detail.Error, &message) != nil {
			var nested struct{ Message string }
			if json.Unmarshal(detail.Error, &nested) == nil {
				message = nested.Message
			}
		}
		if message == "" {
			message = http.StatusText(res.StatusCode)
		}
		return fmt.Errorf("HTTP %d: %s", res.StatusCode, message)
	}
	if len(raw) > maxText {
		return errors.New("model response exceeded 1 MiB")
	}
	return json.Unmarshal(raw, out)
}

func models(provider, base, key string) (string, error) {
	type item struct{ ID, Name string }
	var response struct{ Models, Data []item }
	route := "/v1/models"
	if provider == "ollama" {
		route, key = "/api/tags", ""
	}
	if err := request(base, route, key, nil, &response); err != nil {
		return "", err
	}
	var names []string
	for _, model := range append(response.Models, response.Data...) {
		name := model.ID
		if name == "" {
			name = model.Name
		}
		if name != "" && !strings.ContainsRune(name, 0) {
			names = append(names, name)
		}
	}
	return strings.Join(names, "\x00"), nil
}

func command(program string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	data, err := exec.CommandContext(ctx, program, args...).Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && len(exit.Stderr) > 0 {
			return nil, fmt.Errorf("%s: %s", program, strings.TrimSpace(string(exit.Stderr)))
		}
		return nil, fmt.Errorf("%s: %w", program, err)
	}
	return data, nil
}

func readAtMost(path string, limit int) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return io.ReadAll(io.LimitReader(file, int64(limit)))
}

type image struct{ mime, data string }

func readImage(path string) (image, error) {
	mimes := map[string]string{
		".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
		".bmp": "image/bmp", ".tif": "image/tiff", ".tiff": "image/tiff",
	}
	data, err := readAtMost(path, maxImage+1)
	if err != nil {
		return image{}, err
	}
	if len(data) > maxImage {
		return image{}, errors.New("image exceeds 20 MiB")
	}
	return image{mimes[strings.ToLower(filepath.Ext(path))], base64.StdEncoding.EncodeToString(data)}, nil
}

func video(path string, frames int) ([]image, string, error) {
	raw, err := command("ffprobe", "-v", "error", "-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1", path)
	if err != nil {
		return nil, "", err
	}
	duration, err := strconv.ParseFloat(strings.TrimSpace(string(raw)), 64)
	if err != nil || duration <= 0 || math.IsNaN(duration) || math.IsInf(duration, 0) {
		return nil, "", errors.New("video has no positive finite duration")
	}
	count := max(1, int(min(float64(frames), duration)))
	tmp, err := os.MkdirTemp("", "ai-renamer-")
	if err != nil {
		return nil, "", err
	}
	defer os.RemoveAll(tmp)
	_, err = command("ffmpeg", "-nostdin", "-v", "error", "-threads", "1", "-filter_threads", "1",
		"-i", path, "-vf", fmt.Sprintf("fps=%g", float64(count)/duration),
		"-frames:v", strconv.Itoa(count), "-q:v", "2", "-threads", "1", filepath.Join(tmp, "frame_%03d.jpg"))
	if err != nil {
		return nil, "", err
	}
	entries, err := os.ReadDir(tmp)
	if err != nil {
		return nil, "", err
	}
	if len(entries) == 0 {
		return nil, "", errors.New("no video frames could be extracted")
	}
	var images []image
	for _, entry := range entries {
		frame, err := readImage(filepath.Join(tmp, entry.Name()))
		if err != nil {
			return nil, "", err
		}
		images = append(images, frame)
	}
	return images, fmt.Sprintf("Analyze these %d frames from a %.1f-second video. One frame every %.1f seconds.",
		len(images), duration, duration/float64(count)), nil
}

func filePrompt(kind, rawFrames, path, prompt, custom string) (string, []image, error) {
	var images []image
	switch kind {
	case "image":
		item, err := readImage(path)
		if err != nil {
			return "", nil, err
		}
		images = append(images, item)
	case "video":
		frames, err := strconv.Atoi(rawFrames)
		if err != nil {
			return "", nil, err
		}
		var context string
		images, context, err = video(path, frames)
		if err != nil {
			return "", nil, err
		}
		prompt = context + "\n\n" + prompt
	default:
		var content []byte
		var err error
		if kind == "pdf" {
			content, err = command("pdftotext", path, "-")
			content = content[:min(len(content), maxText)]
		} else {
			content, err = readAtMost(path, maxText)
		}
		if err != nil {
			return "", nil, err
		}
		text := strings.TrimSpace(string(content))
		if text == "" {
			return "", nil, errors.New("no text content")
		}
		prompt += "\n\nContent:\n" + text
	}
	if custom != "" {
		prompt += "\n\nCustom instructions:\n" + custom
	}
	return prompt, images, nil
}

func suggest(args []string) (string, error) {
	provider, base, key, model := args[0], args[1], args[2], args[3]
	prompt, images, err := filePrompt(args[4], args[5], args[6], args[7], args[8])
	if err != nil {
		return "", err
	}
	payload := map[string]any{"model": model, "stream": false}
	if provider == "ollama" {
		payload["prompt"] = prompt
		var encoded []string
		for _, item := range images {
			encoded = append(encoded, item.data)
		}
		if len(encoded) > 0 {
			payload["images"] = encoded
		}
		var result struct{ Response *string }
		if err := request(base, "/api/generate", "", payload, &result); err != nil {
			return "", err
		}
		if result.Response == nil {
			return "", errors.New("model did not return text")
		}
		return *result.Response, nil
	}
	parts := []map[string]any{{"type": "text", "text": prompt}}
	for _, item := range images {
		parts = append(parts, map[string]any{"type": "image_url", "image_url": map[string]string{
			"url": "data:" + item.mime + ";base64," + item.data,
		}})
	}
	payload["messages"] = []map[string]any{{"role": "user", "content": parts}}
	var result struct {
		Choices []struct{ Message struct{ Content *string } }
	}
	if err := request(base, "/v1/chat/completions", key, payload, &result); err != nil {
		return "", err
	}
	if len(result.Choices) == 0 || result.Choices[0].Message.Content == nil {
		return "", errors.New("model did not return text")
	}
	return *result.Choices[0].Message.Content, nil
}
