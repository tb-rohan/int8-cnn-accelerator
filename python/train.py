import argparse
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader
from torchvision import datasets, transforms


class MnistCnn(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(4, 8, 3, padding=1)
        self.conv2 = nn.Conv2d(8, 8, 3, padding=1)
        self.fc = nn.Linear(392, 10)

    def forward(self, image):
        first = torch.relu(self.conv1(image))
        pooled_first = nn.functional.max_pool2d(first, 2)
        second = torch.relu(self.conv2(pooled_first))
        pooled_second = nn.functional.max_pool2d(second, 2)
        scores = self.fc(pooled_second.flatten(1))
        return scores, first, pooled_first, second, pooled_second


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="data")
    parser.add_argument("--output", default="artifacts/mnist_cnn.pt")
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=128)
    args = parser.parse_args()
    torch.manual_seed(7)
    transform = transforms.ToTensor()
    dataset = datasets.MNIST(args.data, train=True, download=True, transform=transform)
    loader = DataLoader(dataset, batch_size=args.batch_size, shuffle=True)
    model = MnistCnn()
    optimizer = torch.optim.Adam(model.parameters(), lr=0.001)
    criterion = nn.CrossEntropyLoss()
    model.train()
    for epoch in range(args.epochs):
        total_loss = 0.0
        for image, label in loader:
            padded = torch.cat((image, torch.zeros(image.shape[0], 3, 28, 28)), dim=1)
            optimizer.zero_grad()
            scores, _, _, _, _ = model(padded)
            loss = criterion(scores, label)
            loss.backward()
            optimizer.step()
            total_loss += float(loss.detach())
        print(f"epoch={epoch + 1} mean_loss={total_loss / len(loader):.5f}")
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    torch.save(model.cpu().state_dict(), output)


if __name__ == "__main__":
    main()
